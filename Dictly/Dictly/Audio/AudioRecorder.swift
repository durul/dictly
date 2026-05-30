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

    /// Recreated on every `start()` so the engine binds to the *current* default
    /// input device. With a single shared instance, AirPods (or any device
    /// connected after launch) report a 24 kHz mono format on the bus but
    /// deliver bit-perfect zero audio — the engine is still pinned to whichever
    /// device was default at first activation. Recreating fixes that.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var samples: [Float] = []
    private var startedAt: Date?
    private var tapCallbacks: Int = 0

    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: AudioRecorder.targetSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    // MARK: - Lifecycle

    func start() throws {
        guard state == .idle else { return }

        // Tear down whatever the previous run left behind. Even if `stop()`
        // already cleaned up, it's cheap to be defensive here.
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)   // safe even if no tap is installed

        do {
            try bringUpEngine()
        } catch let error as NSError where error.code == -10868 {
            // kAudioFormatUnsupportedFormatError. Almost always transient —
            // the audio route is mid-transition (BT pairing handshake, default
            // input device just changed because another app released its hold).
            // Wait a beat, recreate the engine, try once more.
            Self.log.notice("AVAudio start failed with -10868; retrying with fresh engine after 250ms")
            usleep(250_000)
            try bringUpEngine()
        }

        state = .recording
        let inputFmt = engine.inputNode.outputFormat(forBus: 0)
        Self.log.info("Recording started; engine.isRunning=\(self.engine.isRunning) inputFormat=\(String(format: "%.0f", inputFmt.sampleRate))Hz/\(inputFmt.channelCount)ch")
    }

    /// Single attempt to spin up a fresh engine, bind to the default input,
    /// install the tap, and start. Called by `start()` once, and once more
    /// after a short delay if the first attempt hits -10868.
    private func bringUpEngine() throws {
        // Replace the engine entirely so it re-binds to whatever input device is
        // currently the system default. AVAudioEngine's `inputNode` caches its
        // device at first activation; if the user later connects AirPods, the
        // shared engine keeps reporting samples from the original device — or
        // worse, the bus advertises the new format but the buffers come back
        // as zeros. A fresh `AVAudioEngine()` queries the *current* default input.
        engine = AVAudioEngine()

        // Even with a fresh engine, AVAudioEngine sometimes hands us an AUHAL
        // input unit pointing at the *previous* device after a Bluetooth
        // hot-swap (engine.isRunning=true, inputFormat looks plausible, but
        // tapCallbacks=0). Force a rebind to the system's current default
        // input — properly bracketed with uninit/init, the property only
        // changes when the unit isn't running.
        Self.bindInputToDefaultDevice(engine: engine)

        converter = nil
        sourceFormat = nil
        samples.removeAll(keepingCapacity: true)
        currentLevel = 0
        startedAt = Date()
        tapCallbacks = 0

        // After bindInputToDefaultDevice rebinds the AUHAL's underlying device
        // via Core Audio APIs, AVAudioInputNode keeps the *previous* device's
        // format in its cache. `format: nil` then installs the tap at the
        // stale rate (e.g. 96k from the prior device) while the new HW is at
        // 48k — AVAudioEngineGraph rejects the mismatch with -10868 at
        // engine.start(). Read the AU's real current stream format and pass
        // it explicitly so the bus negotiates against the truth.
        let tapFormat = Self.actualInputFormat(engine: engine)
            ?? engine.inputNode.outputFormat(forBus: 0)
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

    /// Pin the engine's input AudioUnit to the current system default input
    /// device. We compare what the unit is *currently* pointing at vs. the
    /// system default; if they match, do nothing (avoids touching the unit
    /// when there's no need). When they differ, we uninitialize → set device
    /// → reinitialize — the only valid sequence for changing
    /// `kAudioOutputUnitProperty_CurrentDevice` (you can't set it on a
    /// running unit, which is what produced the prior `-10877` errors).
    ///
    /// The property selector is `kAudioOutputUnitProperty_CurrentDevice` even
    /// though we're configuring the *input*; that's the AUHAL convention,
    /// the same property identifies the device for input and output units.
    private static func bindInputToDefaultDevice(engine: AVAudioEngine) {
        guard let unit = engine.inputNode.audioUnit else {
            log.error("bindInput: inputNode has no audioUnit")
            return
        }

        // What is the AU currently pointing at?
        var currentID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &currentID, &size)

        // What is the system default input device?
        var defaultID = AudioDeviceID(0)
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &defSize, &defaultID
        )
        guard getStatus == noErr, defaultID != 0 else {
            log.error("bindInput: read default input failed, OSStatus=\(getStatus)")
            return
        }

        log.info("bindInput: AU=\(currentID) default=\(defaultID)")
        if currentID == defaultID { return }   // nothing to do

        // Bracketed property change: only valid while the unit is uninitialized.
        let uninitStatus = AudioUnitUninitialize(unit)
        var idVar = defaultID
        let setStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &idVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        // Changing CurrentDevice updates the input scope (bus 1) to the new
        // HW format, but the output scope keeps the *previous* device's
        // client format. AVAudioEngine compares the two at graph init and
        // panics with "Format mismatch: input hw 48k, client format 96k"
        // followed by -10868 / "Failed to create tap, config change pending".
        // Mirror the new HW format onto the output scope so the AU's two
        // sides agree before we re-initialize.
        var hwFormat = AudioStreamBasicDescription()
        var hwSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let hwReadStatus = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &hwFormat,
            &hwSize
        )
        var syncStatus: OSStatus = noErr
        if hwReadStatus == noErr {
            syncStatus = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &hwFormat,
                hwSize
            )
        }

        let initStatus = AudioUnitInitialize(unit)

        if setStatus == noErr {
            log.info("bindInput: rebound \(currentID) -> \(defaultID) hw=\(String(format: "%.0f", hwFormat.mSampleRate))Hz/\(hwFormat.mChannelsPerFrame)ch syncStatus=\(syncStatus)")
        } else {
            log.error("bindInput: SetProperty failed, OSStatus=\(setStatus) (uninit=\(uninitStatus) init=\(initStatus))")
        }
    }

    /// Reads the AUHAL input unit's actual output stream format directly via
    /// the Core Audio property API. Necessary after `bindInputToDefaultDevice`
    /// because `engine.inputNode.outputFormat(forBus: 0)` returns
    /// AVAudioInputNode's *cached* format from before the device rebind —
    /// pulling the truth from the AU avoids the cached/actual format
    /// mismatch that otherwise trips AVAudioEngineGraph with -10868.
    ///
    /// Bus 1, output scope: the AUHAL's "audio going into the engine from the
    /// hardware" side, which is what the tap on input bus 0 ultimately reads.
    private static func actualInputFormat(engine: AVAudioEngine) -> AVAudioFormat? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &asbd,
            &size
        )
        guard status == noErr, asbd.mSampleRate > 0 else {
            log.notice("actualInputFormat: AudioUnitGetProperty failed, OSStatus=\(status)")
            return nil
        }
        return AVAudioFormat(streamDescription: &asbd)
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
