import AppKit
import Combine

/// Top-level orchestrator. Holds the long-lived components and routes the
/// hotkey → record → transcribe → insert pipeline.
@MainActor
final class DictationCoordinator {

    private static let log = AppLogger(category: "Coordinator")

    enum Phase: Equatable {
        case idle
        case modelLoading(progress: Double)
        case recording
        case transcribing
        case inserted
        case error(String)
    }

    let hotkey = HotkeyManager()
    /// Optional second hotkey pinned to `Settings.secondaryLanguage` (GitHub #1).
    let secondaryHotkey = HotkeyManager()
    let recorder = AudioRecorder()
    let inserter = TextInserter()
    let hud = RecordingHUDController()
    private(set) var transcriber: Transcriber = TranscriberFactory.make()
    private(set) var postProcessor: TextPostProcessor = BasicPostProcessor()

    /// Published phase for UI subscribers (HUD, settings, menu bar).
    let phase = CurrentValueSubject<Phase, Never>(.idle)

    private var subscriptions = Set<AnyCancellable>()
    private(set) var isModelReady = false
    private var transcribeTask: Task<Void, Never>?

    /// Polls for Accessibility while a modifier-only hotkey is set but not yet
    /// trusted, so we can re-register the global monitor the moment it's granted —
    /// no app relaunch required.
    private var accessibilityWatchTimer: Timer?

    /// Whether we've already shown the "grant Accessibility" alert this session,
    /// so a user who's chosen "Not Now" isn't nagged on every dictation.
    private var didPromptAccessibilityThisSession = false

    /// Same, for the "your modifier-only hotkey needs Accessibility" startup warning.
    private var didWarnModifierHotkeyThisSession = false

    init() {
        bind()
    }

    private func bind() {
        Settings.shared.didChange
            .sink { [weak self] in self?.applySettings() }
            .store(in: &subscriptions)

        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }

        // The secondary hotkey doesn't record — it flips the active dictation
        // language between the two chosen languages (GitHub #1).
        secondaryHotkey.onPress = { [weak self] in self?.toggleActiveLanguage() }

        // Audio level updates flow straight to the HUD — they're a per-buffer
        // signal (10–40 Hz) that no other subscriber consumes. Re-emitting them
        // through `phase` made the menu-bar controller re-render its icon /
        // tooltip at audio rate for nothing. The HUD waveform itself is the
        // only meaningful consumer; it gates by its own `.live` style internally.
        recorder.onLevel = { [weak self] level in
            self?.hud.update(level: level)
        }
    }

    func start() {
        applySettings()
        hotkey.start()
        // Deferred to the next runloop tick so a modal alert never blocks launch.
        DispatchQueue.main.async { [weak self] in self?.warnIfModifierHotkeyNeedsAccessibility() }
        Task { await prepareModelInBackground() }
    }

    func stop() {
        hotkey.stop()
        secondaryHotkey.stop()
        transcribeTask?.cancel()
    }

    private func applySettings() {
        hotkey.update(combo: Settings.shared.hotkey)

        // Reconcile the optional secondary hotkey. `stop()` is a safe no-op when
        // it isn't running; `update` then `start` (which stops first) install
        // cleanly with the current combo.
        secondaryHotkey.stop()
        if Settings.shared.secondaryLanguageEnabled {
            secondaryHotkey.update(combo: Settings.shared.secondaryHotkey)
            secondaryHotkey.start()
        }

        // Re-evaluate the Accessibility watch (the active hotkey may have changed
        // to/from a modifier-only combo).
        startAccessibilityWatchIfNeeded()
    }

    /// Translate raw Core Audio / AVFoundation errors into something a user can act on.
    /// AVAudioEngine surfaces OSStatus codes via `(com.apple.coreaudio.avfaudio error N.)`
    /// strings that are meaningless without a reference table.
    private static func friendlyAudioErrorMessage(for error: NSError) -> String {
        switch error.code {
        case -10868:
            // kAudioFormatUnsupportedFormatError — most often a transient route
            // change (BT pairing, another app releasing the mic). We already retry
            // once internally; reaching this branch means the second try also failed.
            return "Mic unavailable — try again"
        case -10851, -10877:
            // kAudioUnitErr_InvalidProperty / NoConnection — input device gone away.
            return "Mic disconnected"
        case -10863:
            // kAudioHardwareNotRunningError
            return "Audio system not ready — try again"
        default:
            return "Couldn't start recording"
        }
    }

    func prepareModelInBackground() async {
        let id = Settings.shared.modelID
        Self.log.info("Preparing model \(id)")
        phase.send(.modelLoading(progress: 0))
        do {
            try await transcriber.prepare(modelID: id) { [weak self] p in
                self?.phase.send(.modelLoading(progress: p))
            }
            isModelReady = true
            phase.send(.idle)
        } catch {
            Self.log.error("Model load failed: \(error.localizedDescription)")
            phase.send(.error(error.localizedDescription))
        }
    }

    // MARK: Hotkey routing

    private func hotkeyPressed() {
        switch Settings.shared.hotkeyMode {
        case .pushToTalk:
            beginRecording()
        case .toggle:
            if recorder.state == .recording {
                endRecordingAndTranscribe()
            } else {
                beginRecording()
            }
        }
    }

    /// Flip the active dictation language between the two chosen languages. Fires
    /// `didChange`, which refreshes the menu-bar language indicator (the visible
    /// feedback the user sees next to the icon).
    private func toggleActiveLanguage() {
        guard Settings.shared.secondaryLanguageEnabled else { return }
        Settings.shared.secondaryLanguageActive.toggle()
        Self.log.info("Active language switched to \(Settings.shared.activeLanguage)")
    }

    private func hotkeyReleased() {
        guard Settings.shared.hotkeyMode == .pushToTalk else { return }
        // Read the recorder's own state — the phase may not have caught up yet on a very
        // quick tap (the engine takes a few ms to deliver the first level update).
        if recorder.state == .recording { endRecordingAndTranscribe() }
    }

    // MARK: Recording

    private func beginRecording() {
        guard isModelReady else {
            hud.flash(message: "Loading model…")
            return
        }
        guard PermissionsChecker.microphoneStatus == .authorized else {
            Task {
                let ok = await PermissionsChecker.requestMicrophone()
                if ok { self.beginRecording() }
                else { self.hud.flash(message: "Microphone access denied") }
            }
            return
        }

        do {
            try recorder.start()
            // Go straight to "Listening" — the first audible buffer typically arrives
            // <100 ms after `engine.start()` on built-in / wired mics, and showing an
            // intermediate "Connecting…" state for that window felt sluggish next to
            // tools like the original Whisper. On Bluetooth (SCO) the user may lose
            // ~200–400 ms of leading speech while the voice profile is being set up,
            // but that's the same trade-off every other dictation app makes.
            phase.send(.recording)
            if Settings.shared.showHUD { hud.show(state: .recording) }
        } catch {
            let nsError = error as NSError
            Self.log.error("recorder.start failed: code=\(nsError.code) domain=\(nsError.domain) desc=\(error.localizedDescription)")
            let friendly = Self.friendlyAudioErrorMessage(for: nsError)
            phase.send(.error(friendly))
            hud.show(state: .error(friendly))
            hud.hideAfter(seconds: 1.9)
            phase.send(.idle)
        }
    }

    private func endRecordingAndTranscribe() {
        let samples = recorder.stop()
        let durationSec = Double(samples.count) / AudioRecorder.targetSampleRate
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        Self.log.info("endRecording: \(samples.count) samples (\(String(format: "%.2f", durationSec))s)")

        // Whisper needs a real chunk of audio to detect speech reliably. A 100 ms tap on
        // the hotkey produces under that, and the model returns empty — surface a hint
        // instead of "Silence" so the user knows to hold longer.
        if durationSec < 0.4 {
            phase.send(.error("Hold longer"))
            hud.show(state: .error("Hold the hotkey while you speak"))
            hud.hideAfter(seconds: 1.9)
            phase.send(.idle)
            return
        }

        let language = Settings.shared.activeLanguage
        let fallbackCount = Settings.shared.transcriptionQuality.fallbackCount
        phase.send(.transcribing)
        if Settings.shared.showHUD { hud.show(state: .transcribing) }

        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            await self?.runTranscription(samples: samples, language: language,
                                          fallbackCount: fallbackCount,
                                          pipelineStart: pipelineStart)
        }
    }

    /// Shown once per session when auto-paste is blocked by missing Accessibility.
    /// A modal alert is far harder to miss than the HUD flash, and gives the user
    /// a one-click path to System Settings.
    private func promptAccessibilityOnce() {
        guard !didPromptAccessibilityThisSession else { return }
        didPromptAccessibilityThisSession = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dictly can't paste automatically yet"
        alert.informativeText = """
        Your dictation was copied to the clipboard — press ⌘V to paste it.

        To let Dictly type into apps for you, grant it Accessibility access in \
        System Settings → Privacy & Security → Accessibility, then add Dictly.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")

        // The app is a menu-bar agent (.accessory); bring it forward so the alert
        // is visible above whatever the user was dictating into.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            PermissionsChecker.promptAccessibilityIfNeeded(reason: "dictation-blocked")
            PermissionsChecker.openAccessibilitySettings()
        }
    }

    /// A global `NSEvent` key monitor (the modifier-only hotkey path) only starts
    /// receiving events once the app is trusted for Accessibility — and a monitor
    /// installed *before* the grant stays dead. So while a modifier-only hotkey is
    /// set but not trusted, poll; the instant access is granted, re-register the
    /// monitors so the hotkey works without an app relaunch.
    private func startAccessibilityWatchIfNeeded() {
        accessibilityWatchTimer?.invalidate()
        accessibilityWatchTimer = nil
        guard Settings.shared.hotkey.kind == .modifierOnly else { return }   // Carbon combos don't need it
        guard !PermissionsChecker.isAccessibilityGranted else { return }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reRegisterHotkeysIfNowTrusted() }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityWatchTimer = timer
    }

    private func reRegisterHotkeysIfNowTrusted() {
        guard PermissionsChecker.isAccessibilityGranted else { return }
        accessibilityWatchTimer?.invalidate()
        accessibilityWatchTimer = nil
        Self.log.notice("Accessibility granted — re-registering hotkey monitors")
        hotkey.stop();  hotkey.start()
        if Settings.shared.secondaryLanguageEnabled {
            secondaryHotkey.stop(); secondaryHotkey.start()
        }
    }

    /// At launch, if the active hotkey is modifier-only (Fn, right Option…) and
    /// Accessibility isn't granted, the global key monitor receives nothing and the
    /// hotkey silently does nothing — the most confusing failure mode in the app.
    /// Warn once, with a path to fix it. Key-combo hotkeys use Carbon and need no
    /// permission, so they're exempt.
    private func warnIfModifierHotkeyNeedsAccessibility() {
        guard Settings.shared.didCompleteOnboarding else { return }   // onboarding already covers this
        guard !didWarnModifierHotkeyThisSession else { return }
        guard Settings.shared.hotkey.kind == .modifierOnly else { return }
        guard !PermissionsChecker.isAccessibilityGranted else { return }
        didWarnModifierHotkeyThisSession = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your push-to-talk key needs Accessibility access"
        alert.informativeText = """
        “\(Settings.shared.hotkey.displayName)” is a modifier-only hotkey. macOS only \
        delivers it to apps trusted for Accessibility, so recording won't start until you \
        grant access.

        Grant Dictly Accessibility access — or pick a regular key combination (e.g. ⌃⌥Space) \
        in Settings, which works without any permission.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsChecker.promptAccessibilityIfNeeded(reason: "modifier-hotkey")
            PermissionsChecker.openAccessibilitySettings()
        }
    }

    private func runTranscription(samples: [Float], language: String,
                                   fallbackCount: Int,
                                   pipelineStart: CFAbsoluteTime) async {
        do {
            let transcribeStart = CFAbsoluteTimeGetCurrent()
            guard let raw = try await transcriber.transcribe(samples: samples, language: language, fallbackCount: fallbackCount) else {
                Self.log.notice("Transcribe returned empty for \(samples.count) samples (lang=\(language))")
                phase.send(.error("No speech detected"))
                hud.show(state: .error("No speech detected"))
                hud.hideAfter(seconds: 1.9)
                phase.send(.idle)
                return
            }
            let transcribeSec = CFAbsoluteTimeGetCurrent() - transcribeStart
            Self.log.info("Transcribe ok: \(raw.count) chars")

            let postStart = CFAbsoluteTimeGetCurrent()
            let processed = (try? await postProcessor.process(raw, language: language)) ?? raw
            let postSec = CFAbsoluteTimeGetCurrent() - postStart

            let words = processed.split { $0.isWhitespace }.count
            let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName

            let insertStart = CFAbsoluteTimeGetCurrent()
            let outcome = inserter.insert(processed)
            let insertSec = CFAbsoluteTimeGetCurrent() - insertStart

            let totalSec = CFAbsoluteTimeGetCurrent() - pipelineStart
            let audioSec = Double(samples.count) / AudioRecorder.targetSampleRate
            // Single-line summary at `.notice` so it shows in Xcode console and
            // Console.app by default (no need to enable "Info messages").
            Self.log.notice("pipeline: total=\(String(format: "%.2f", totalSec))s (transcribe=\(String(format: "%.2f", transcribeSec))s post=\(String(format: "%.2f", postSec))s insert=\(String(format: "%.2f", insertSec))s) for \(String(format: "%.2f", audioSec))s audio")

            switch outcome {
            case .insertedAutomatically:
                phase.send(.inserted)
                hud.show(state: .inserted(words: words, app: frontApp))
                hud.hideAfter(seconds: 1.9)
            case .copiedToClipboard:
                phase.send(.inserted)
                hud.show(state: .copiedToClipboard)
                hud.hideAfter(seconds: 1.9)
            case .missingAccessibilityPermission:
                // Auto-paste was on but Accessibility isn't granted. The HUD flash
                // alone is too easy to miss (it vanished before the user could read
                // it), so keep it up longer AND surface a one-time actionable alert.
                phase.send(.inserted)
                hud.show(state: .needsAccessibility)
                hud.hideAfter(seconds: 5)
                promptAccessibilityOnce()
            }
            phase.send(.idle)
        } catch {
            Self.log.error("Transcribe failed: \(error.localizedDescription)")
            phase.send(.error(error.localizedDescription))
            hud.show(state: .error(error.localizedDescription))
            hud.hideAfter(seconds: 1.5)
            phase.send(.idle)
        }
    }
}
