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

    init() {
        bind()
    }

    private func bind() {
        Settings.shared.didChange
            .sink { [weak self] in self?.applySettings() }
            .store(in: &subscriptions)

        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }

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
        Task { await prepareModelInBackground() }
    }

    func stop() {
        hotkey.stop()
        transcribeTask?.cancel()
    }

    private func applySettings() {
        hotkey.update(combo: Settings.shared.hotkey)
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

        let language = Settings.shared.language
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
            case .copiedToClipboard:
                phase.send(.inserted)
                hud.show(state: .copiedToClipboard)
            case .missingAccessibilityPermission:
                phase.send(.inserted)
                hud.show(state: .needsAccessibility)
            }
            hud.hideAfter(seconds: 1.9)
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
