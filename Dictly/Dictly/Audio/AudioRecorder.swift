import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Captures microphone audio and produces a Whisper-ready buffer:
/// 16 kHz, mono, Float32 PCM. Maintains a peak meter for the HUD.
///
/// **Cold-start design.** The audio engine boots in `start()` and is fully torn down in
/// `stop()`. As a result, macOS only shows the orange "mic in use" indicator while a
/// recording is actively in progress — which is what the user expects from a privacy
/// standpoint.
///
/// **Trade-off for Bluetooth mics.** AirPods / BT headsets need ~200–400 ms after
/// `engine.start()` to negotiate the SCO voice profile. During that window the tap
/// fires but buffers are silent. Whisper tolerates a brief pre-speech silence, so this
/// is fine for normal use, but the very first ~300 ms of speech may be missed if the
/// user starts talking the instant they press the hotkey on a cold engine. Hold the
/// hotkey a beat before speaking on Bluetooth, or use the built-in mic for snap taps.
@MainActor
final class AudioRecorder {

    private static let log = AppLogger(category: "Audio")

    static let targetSampleRate: Double = 16_000

    /// Hard cap to protect memory and stay under Whisper's 30-second window.
    static let maxDurationSeconds: TimeInterval = 120

    enum State { case idle, recording }
    private(set) var state: State = .idle

    /// Most recent normalized [0...1] peak across the buffer; updated for HUD waveform.
    private(set) var currentLevel: Float = 0
    var onLevel: ((Float) -> Void)?

    /// A single long-lived engine, reused across recordings. It follows the system
    /// default input; we recreate it only when that device changes (see
    /// `bringUpEngine`) — and must not recreate per recording: that spins up a
    /// second AUHAL unit on the same device while the previous one's IO thread is
    /// still alive, which fails the next start with "there already is a thread" on
    /// proxied devices (Bluetooth / Continuity / virtual mics).
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var samples: [Float] = []
    private var startedAt: Date?
    private var tapCallbacks: Int = 0

    /// System default input device the current `engine` was built for — numeric id
    /// AND UID. When either changes we recreate the engine so AVAudioEngine
    /// re-queries the new device — but NOT on every recording. Both are compared
    /// because neither alone is reliable: Core Audio can recycle a numeric id for
    /// a different device, and the same device can reconnect under a new id.
    private var lastConfiguredInputID: AudioDeviceID = 0
    private var lastConfiguredInputUID: String?
    /// Set when a start attempt failed — the engine may be half-configured, so the
    /// next attempt rebuilds it instead of trusting `lastConfiguredInput*`.
    private var engineNeedsRebuild = false

    // MARK: Keep-warm (pre-roll)

    /// Desired keep-warm state (mirrors `Settings.keepMicWarm`). When active, the
    /// engine and tap keep running between recordings: a take starts instantly
    /// (no AUHAL spin-up, no mic-hardware wake — 2–5 s cold on Apple Silicon) and
    /// the tap retains the trailing `preRollCapacity` samples, so speech that
    /// begins a beat before the hotkey press is still captured.
    private var warmEnabled = false
    /// Whether the engine is actually running warm right now. Distinct from
    /// `warmEnabled`: warm is skipped for Bluetooth inputs, without mic
    /// permission, and after a failed bring-up (falls back to on-demand starts).
    private var warmActive = false
    /// Converted 16 kHz mono samples captured while warm-idle; spliced into the
    /// start of the next recording.
    private var preRoll: [Float] = []
    /// How many of the current take's samples came from the pre-roll. The
    /// coordinator subtracts this when judging how long the key was held.
    private(set) var lastPreRollCount = 0
    private static let preRollCapacity = Int(AudioRecorder.targetSampleRate) / 2   // 0.5 s

    private var configChangeObserver: NSObjectProtocol?

    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: AudioRecorder.targetSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    // MARK: - Lifecycle

    init() {
        // Rebuild a warm-idle engine when its device/config changes underneath it
        // (mic unplugged, system default switched by the menu-bar picker, format
        // change). In-flight recordings are left alone — they end via user action.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            let changedID = (note.object as? AVAudioEngine).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, let changedID,
                      changedID == ObjectIdentifier(self.engine) else { return }
                self.engineConfigurationChanged()
            }
        }
    }

    deinit {
        if let o = configChangeObserver { NotificationCenter.default.removeObserver(o) }
    }

    func start() throws {
        guard state == .idle else { return }

        // Warm fast path: the engine is already capturing on the current default
        // device — splice the pre-roll and flip state. This is the entire point
        // of keep-warm: no spin-up inside the hotkey press, no first-word loss.
        if warmActive && engine.isRunning,
           (AudioDeviceManager.defaultInputDeviceID() ?? 0) == lastConfiguredInputID {
            samples = preRoll
            lastPreRollCount = preRoll.count
            preRoll.removeAll(keepingCapacity: true)
            startedAt = Date()
            tapCallbacks = 0
            currentLevel = 0
            state = .recording
            Self.log.info("Recording started (warm), pre-roll=\(self.lastPreRollCount) samples")
            return
        }
        // Warm engine unusable (device changed / engine died) — take the cold
        // path below; stop() re-engages warm afterwards via reconcileWarm().
        if warmActive {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            warmActive = false
            preRoll.removeAll(keepingCapacity: false)
            engineNeedsRebuild = true
        }
        lastPreRollCount = 0

        do {
            do {
                try bringUpEngine()
            } catch let error as NSError where error.code == -10868 {
                // kAudioFormatUnsupportedFormatError. Almost always transient — the
                // audio route is mid-transition (BT handshake, default input changed).
                // As a last resort, recreate the engine from scratch and retry once.
                Self.log.notice("AVAudio start failed with -10868; recreating engine and retrying after 250ms")
                usleep(250_000)
                engine.inputNode.removeTap(onBus: 0)
                if engine.isRunning { engine.stop() }
                engine = AVAudioEngine()
                try bringUpEngine()
            }
        } catch {
            engineNeedsRebuild = true
            throw error
        }

        state = .recording
        let inputFmt = engine.inputNode.outputFormat(forBus: 0)
        Self.log.info("Recording started; engine.isRunning=\(self.engine.isRunning) inputFormat=\(String(format: "%.0f", inputFmt.sampleRate))Hz/\(inputFmt.channelCount)ch")
    }

    /// Prepare the engine and start capture.
    ///
    /// The engine is **reused** across recordings — recreating it per take spun up
    /// a second AUHAL unit on the same device while the previous IO thread was
    /// still alive ("there already is a thread" / StartIO err 35), fatal for
    /// proxied devices (Bluetooth / Continuity / virtual mics). We recreate it
    /// only when the system default input actually changes, so AVAudioEngine
    /// re-queries the new device.
    ///
    /// We deliberately do NO manual AUHAL device rebinding here: the
    /// uninit→set→init dance refused to re-engage proxied devices after the first
    /// use. Device selection is applied by setting the *system default* input (see
    /// the menu-bar mic picker); the plain input node then follows it.
    private func bringUpEngine() throws {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)

        let currentInput = AudioDeviceManager.defaultInputDeviceID() ?? 0
        let currentUID = currentInput != 0 ? AudioDeviceManager.uid(for: currentInput) : nil
        if engineNeedsRebuild || currentInput != lastConfiguredInputID
            || currentUID != lastConfiguredInputUID {
            engine = AVAudioEngine()
            engineNeedsRebuild = false
            lastConfiguredInputID = currentInput
            lastConfiguredInputUID = currentUID
            Self.log.info("Engine (re)created for input device \(currentInput) uid=\(currentUID ?? "-")")
        }

        converter = nil
        sourceFormat = nil
        samples.removeAll(keepingCapacity: true)
        currentLevel = 0
        startedAt = Date()
        tapCallbacks = 0

        let tapFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processTap(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        guard state == .recording else { return [] }
        state = .idle

        if warmActive && engine.isRunning {
            // Keep-warm: leave the engine and tap running — the tap goes straight
            // back to filling the pre-roll for the next take.
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // Prepare-ahead (VoiceInk-style): preallocate now so the next cold
            // start pays less inside the hotkey press.
            engine.prepare()
        }

        let result = samples
        samples.removeAll(keepingCapacity: false)
        currentLevel = 0

        var peak: Float = 0
        for v in result { let a = v < 0 ? -v : v; if a > peak { peak = a } }
        let durationSec = Double(result.count) / Self.targetSampleRate
        Self.log.info(
            "Recording stopped; samples=\(result.count) (\(String(format: "%.2f", durationSec))s) peak=\(String(format: "%.4f", peak)) tapCallbacks=\(self.tapCallbacks)"
        )
        if self.tapCallbacks == 0 {
            Self.log.notice("No tap callbacks fired — engine never delivered audio")
        } else if peak < 0.005 {
            Self.log.notice("Mic captured near-silence (peak \(String(format: "%.4f", peak)))")
        }
        // Warm state may need to change: settings toggled mid-take, device moved
        // on/off Bluetooth, or warm needs (re-)engaging after a cold take.
        reconcileWarm()
        return result
    }

    // MARK: - Keep-warm

    /// Coordinator-facing switch, re-applied on every settings change.
    func setWarmMode(_ enabled: Bool) {
        warmEnabled = enabled
        reconcileWarm()
    }

    /// Bring the idle engine up or down to match `warmEnabled`. No-op while a
    /// recording is in flight — `stop()` re-invokes this afterwards.
    private func reconcileWarm() {
        guard state == .idle else { return }
        let wantWarm = warmEnabled && Self.warmSupported()
        if wantWarm && !warmActive {
            do {
                try bringUpEngine()
                warmActive = true
                Self.log.info("Mic keep-warm engaged")
            } catch {
                engineNeedsRebuild = true
                Self.log.notice("Keep-warm bring-up failed (\(error.localizedDescription)); falling back to on-demand starts")
            }
        } else if !wantWarm && warmActive {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            warmActive = false
            preRoll.removeAll(keepingCapacity: false)
            Self.log.info("Mic keep-warm disengaged")
        }
    }

    /// Keep-warm needs mic permission (the stream opens immediately) and a
    /// non-Bluetooth input — holding a capture stream open would pin a BT
    /// headset to low-quality SCO call mode system-wide.
    private static func warmSupported() -> Bool {
        guard PermissionsChecker.microphoneStatus == .authorized else { return false }
        guard let id = AudioDeviceManager.defaultInputDeviceID() else { return false }
        return !AudioDeviceManager.isBluetooth(id)
    }

    private func engineConfigurationChanged() {
        guard state == .idle, warmActive else { return }
        Self.log.info("Engine configuration changed while warm-idle — rebuilding")
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        warmActive = false
        preRoll.removeAll(keepingCapacity: false)
        engineNeedsRebuild = true
        reconcileWarm()
    }

    // MARK: - Tap

    private nonisolated func processTap(buffer: AVAudioPCMBuffer) {
        let captured = buffer
        Task { @MainActor [weak self] in
            self?.consume(buffer: captured)
        }
    }

    private func consume(buffer: AVAudioPCMBuffer) {
        // The tap can fire one last time after we've removed it; ignore those.
        // While warm-idle the tap stays installed and feeds the pre-roll instead.
        let recording = state == .recording
        guard recording || warmActive else { return }
        if recording { tapCallbacks += 1 }

        // Snapshot source format once, mostly for diagnostics.
        if sourceFormat == nil {
            sourceFormat = buffer.format
            Self.log.info(
                "First buffer: sampleRate=\(String(format: "%.0f", buffer.format.sampleRate))Hz channels=\(buffer.format.channelCount) commonFormat=\(buffer.format.commonFormat.rawValue) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)"
            )
        }

        let prePeak = peakOf(buffer: buffer)
        if recording && tapCallbacks <= 3 {
            Self.log.info("tap #\(self.tapCallbacks): frames=\(buffer.frameLength) prePeak=\(String(format: "%.4f", prePeak))")
        }

        // Fast path: source already matches target (16 kHz Float32 mono — common for
        // AirPods over SCO). Just copy the channel data, no AVAudioConverter (which
        // emits empty out-buffers for some channel layouts).
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let raw = buffer.floatChannelData?[0] {
            ingest(raw, count: Int(buffer.frameLength), peak: prePeak)
            return
        }

        // Slow path: real format conversion (resample / int→float / channel-mix).
        // The converter is created once per recording session and kept alive
        // across taps so its resampler's filter state stays primed. Per-call
        // creation produced 0-frame outputs after the first buffer.
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            if converter == nil {
                Self.log.error("Failed to create AVAudioConverter from \(buffer.format) to \(self.targetFormat)")
                return
            }
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // Hand exactly one input buffer to the converter. Returning
        // `.noDataNow` (instead of `.endOfStream`) on subsequent pulls keeps
        // the converter open across consume() calls — `endOfStream` latches it
        // into a drained state and produces 0-frame outputs from the next tap
        // onward, which is what we saw in the wild on AirPods (24 kHz → 16 kHz
        // resampling).
        var pendingInput: AVAudioPCMBuffer? = buffer
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if let buf = pendingInput {
                pendingInput = nil
                outStatus.pointee = .haveData
                return buf
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if status == .error {
            Self.log.error("Converter error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        if recording && tapCallbacks <= 3 {
            Self.log.info("tap #\(self.tapCallbacks): converter outFrames=\(outBuffer.frameLength)")
        }

        guard outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData?[0] else { return }

        let frames = Int(outBuffer.frameLength)
        var peak: Float = 0
        for i in 0..<frames {
            let abs = channel[i] < 0 ? -channel[i] : channel[i]
            if abs > peak { peak = abs }
        }
        ingest(channel, count: frames, peak: peak)
    }

    /// Route converted samples into the recording — or, while warm-idle, into
    /// the trailing pre-roll window.
    private func ingest(_ data: UnsafePointer<Float>, count: Int, peak: Float) {
        if state == .recording {
            samples.reserveCapacity(samples.count + count)
            for i in 0..<count { samples.append(data[i]) }
            currentLevel = min(1, peak * 1.5)
            onLevel?(currentLevel)
            checkMaxDuration()
        } else {
            preRoll.reserveCapacity(preRoll.count + count)
            for i in 0..<count { preRoll.append(data[i]) }
            if preRoll.count > Self.preRollCapacity {
                preRoll.removeFirst(preRoll.count - Self.preRollCapacity)
            }
        }
    }

    // MARK: - Helpers

    private func peakOf(buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            if let raw = buffer.floatChannelData?[0] {
                for i in 0..<frames {
                    let a = raw[i] < 0 ? -raw[i] : raw[i]
                    if a > peak { peak = a }
                }
            }
        case .pcmFormatInt16:
            if let raw = buffer.int16ChannelData?[0] {
                var p16: Int16 = 0
                for i in 0..<frames {
                    let v = raw[i] == .min ? .max : (raw[i] < 0 ? -raw[i] : raw[i])
                    if v > p16 { p16 = v }
                }
                peak = Float(p16) / Float(Int16.max)
            }
        case .pcmFormatInt32:
            if let raw = buffer.int32ChannelData?[0] {
                var p32: Int32 = 0
                for i in 0..<frames {
                    let v = raw[i] == .min ? .max : (raw[i] < 0 ? -raw[i] : raw[i])
                    if v > p32 { p32 = v }
                }
                peak = Float(p32) / Float(Int32.max)
            }
        default:
            break
        }
        return peak
    }

    private func checkMaxDuration() {
        if let started = startedAt, Date().timeIntervalSince(started) > Self.maxDurationSeconds {
            _ = stop()
        }
    }
}

enum AudioError: Error, LocalizedError {
    case invalidInputFormat
    case cannotCreateConverter

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat: return "Couldn't read microphone format."
        case .cannotCreateConverter: return "Couldn't create audio converter."
        }
    }
}
