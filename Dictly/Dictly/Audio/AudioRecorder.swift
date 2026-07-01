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

    /// A single long-lived engine, reused across recordings. We bind it to the
    /// chosen input device explicitly (see `bindInput`), so we don't need to
    /// recreate it per recording — and must not: recreating spins up a second
    /// AUHAL unit on the same device while the previous one's IO thread is still
    /// alive, which fails the next start with "there already is a thread" on
    /// proxied devices (Bluetooth / Continuity / virtual mics).
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var samples: [Float] = []
    private var startedAt: Date?
    private var tapCallbacks: Int = 0

    /// System default input device the current `engine` was built for. When it
    /// changes (e.g. the user picks a different mic), we recreate the engine so
    /// AVAudioEngine re-queries the new device — but NOT on every recording.
    private var lastConfiguredInputID: AudioDeviceID = 0

    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: AudioRecorder.targetSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    // MARK: - Lifecycle

    func start() throws {
        guard state == .idle else { return }

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
        if currentInput != lastConfiguredInputID {
            engine = AVAudioEngine()
            lastConfiguredInputID = currentInput
            Self.log.info("Engine (re)created for input device \(currentInput)")
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = .idle

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
        return result
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
        guard state == .recording else { return }
        tapCallbacks += 1

        // Snapshot source format once, mostly for diagnostics.
        if sourceFormat == nil {
            sourceFormat = buffer.format
            Self.log.info(
                "First buffer: sampleRate=\(String(format: "%.0f", buffer.format.sampleRate))Hz channels=\(buffer.format.channelCount) commonFormat=\(buffer.format.commonFormat.rawValue) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)"
            )
        }

        let prePeak = peakOf(buffer: buffer)
        if tapCallbacks <= 3 {
            Self.log.info("tap #\(self.tapCallbacks): frames=\(buffer.frameLength) prePeak=\(String(format: "%.4f", prePeak))")
        }

        // Fast path: source already matches target (16 kHz Float32 mono — common for
        // AirPods over SCO). Just copy the channel data, no AVAudioConverter (which
        // emits empty out-buffers for some channel layouts).
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           let raw = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            samples.reserveCapacity(samples.count + frames)
            for i in 0..<frames { samples.append(raw[i]) }
            currentLevel = min(1, prePeak * 1.5)
            onLevel?(currentLevel)
            checkMaxDuration()
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
        if tapCallbacks <= 3 {
            Self.log.info("tap #\(self.tapCallbacks): converter outFrames=\(outBuffer.frameLength)")
        }

        guard outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData?[0] else { return }

        let frames = Int(outBuffer.frameLength)
        var peak: Float = 0
        samples.reserveCapacity(samples.count + frames)
        for i in 0..<frames {
            let v = channel[i]
            samples.append(v)
            let abs = v < 0 ? -v : v
            if abs > peak { peak = abs }
        }
        currentLevel = min(1, peak * 1.5)
        onLevel?(currentLevel)
        checkMaxDuration()
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
