import Foundation

#if canImport(WhisperKit)
import WhisperKit

/// WhisperKit-backed implementation of `Transcriber`.
///
/// Two load paths:
/// 1. **Bundled model** — for any `modelID` in `ModelInfo.bundledIDs` we point WhisperKit's
///    `modelFolder` directly at the in-bundle copy (`Resources/BundledModels/<folder>/`),
///    so first-launch transcription works fully offline with zero downloads.
/// 2. **HuggingFace download** — for everything else WhisperKit's normal flow runs:
///    snapshot the variant from `argmaxinc/whisperkit-coreml` and cache it under
///    `~/Documents/huggingface/...`.
///
/// The whole class opts out of the project's MainActor default isolation: WhisperKit's
/// async API is intentionally non-isolated and we don't want every property access to
/// require a MainActor hop. Cross-thread access to the cached pipe is mediated by a
/// dedicated serial queue.
nonisolated
final class WhisperKitTranscriber: Transcriber, @unchecked Sendable {

    private static let log = AppLogger(category: "WhisperKit")

    private var pipe: WhisperKit?
    private var loadedID: String?
    private let queue = DispatchQueue(label: "com.mydear.voicetotext.whisperkit.state")

    func prepare(modelID: String, progress: @Sendable @MainActor @escaping (Double) -> Void) async throws {
        let alreadyLoaded = queue.sync { loadedID == modelID && pipe != nil }
        if alreadyLoaded {
            await MainActor.run { progress(1.0) }
            return
        }

        let bundledFolder = Self.bundledModelFolder(for: modelID)
        if bundledFolder != nil {
            Self.log.info("Loading bundled model \(modelID)")
        } else {
            Self.log.info("Loading remote model \(modelID)")
        }
        await MainActor.run { progress(0.0) }

        // Pre-download path. For non-bundled models we run `WhisperKit.download` first so
        // we can pipe its `Progress` updates straight into the UI — `WhisperKit(config)`'s
        // own auto-download has no progress hook, which is why the UI was stuck at 0/50/90.
        let modelFolder: String
        if let bundled = bundledFolder {
            modelFolder = bundled
        } else {
            let folderURL = try await WhisperKit.download(
                variant: modelID,
                progressCallback: { p in
                    let frac = max(0, min(1, p.fractionCompleted))
                    // Reserve the top 5% for the WhisperKit initialisation step that
                    // follows; the heavy lifting (bytes from HuggingFace) is the 0–0.95.
                    Task { @MainActor in
                        progress(frac * 0.95)
                    }
                }
            )
            modelFolder = folderURL.path
            await MainActor.run { progress(0.95) }
        }

        // Now load the (locally-present) model. With `modelFolder` set and `download:
        // false`, WhisperKit reads .mlmodelc files straight off disk — no network.
        let config = WhisperKitConfig(
            model: modelID,
            modelFolder: modelFolder,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )

        let kit = try await WhisperKit(config)
        queue.sync {
            self.pipe = kit
            self.loadedID = modelID
        }

        // Dry-run a short silent buffer before declaring the model "ready".
        // CoreML lazily JIT-compiles parts of the inference graph on the first
        // real call; without warm-up the user's first hotkey press paid 2–5 s
        // of cold-start cost on top of the actual transcribe time. A 1 s
        // silence inference forces those compile/cache paths now, while the
        // onboarding/loading UI is still on screen.
        let warmStart = CFAbsoluteTimeGetCurrent()
        var warmOpts = DecodingOptions()
        warmOpts.task = .transcribe
        warmOpts.language = "en"
        warmOpts.detectLanguage = false
        warmOpts.skipSpecialTokens = true
        warmOpts.withoutTimestamps = true
        warmOpts.temperatureFallbackCount = 0
        warmOpts.sampleLength = 1
        let dummy = [Float](repeating: 0, count: 16_000)
        _ = try? await kit.transcribe(audioArray: dummy, decodeOptions: warmOpts)
        Self.log.info("WhisperKit warmup: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - warmStart))s")

        await MainActor.run { progress(1.0) }
    }

    func transcribe(samples: [Float], language: String, fallbackCount: Int) async throws -> String? {
        let kit = queue.sync { pipe }
        guard let kit else { throw TranscriberError.modelNotLoaded }
        if samples.isEmpty { throw TranscriberError.empty }

        var options = DecodingOptions()
        options.task = .transcribe
        if language != "auto" {
            options.language = language
            options.detectLanguage = false
        } else {
            options.detectLanguage = true
        }
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        // Speed knobs (handoff §perf):
        //   • `temperatureFallbackCount` — caller-supplied. 0 = no retries
        //     (fastest, no recovery from greedy-decoding loops like
        //     "1, 2, 3, 1, 2, 3, …" on noisy audio). Higher = more chances to
        //     recover; cost is paid ONLY when the first pass produces
        //     degenerate output (high compression ratio / low avg-logprob).
        //   • `sampleLength = 128` — hard cap on tokens generated per chunk.
        //     Whisper's default is 224. For typical dictation (≤30 s of
        //     speech, ~10–15 tokens/s) 128 leaves comfortable headroom while
        //     bounding worst-case loop time at ~3 s on bad audio.
        //   • `chunkingStrategy = .vad` — for utterances longer than the 30 s
        //     Whisper window, voice-activity-based chunking skips silence
        //     between phrases instead of decoding it. No-op for short ones.
        options.temperatureFallbackCount = max(0, fallbackCount)
        options.sampleLength = 128
        options.chunkingStrategy = .vad

        let t0 = CFAbsoluteTimeGetCurrent()
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        let audioSec = Double(samples.count) / 16_000.0
        let rtf = audioSec > 0 ? elapsed / audioSec : 0
        Self.log.info("kit.transcribe: \(String(format: "%.2f", elapsed))s for \(String(format: "%.2f", audioSec))s audio (RTF=\(String(format: "%.2f", rtf)))")

        let text = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func unload() async {
        queue.sync {
            pipe = nil
            loadedID = nil
        }
    }

    /// Resolves the absolute path of a bundled model folder, or `nil` if the requested
    /// variant isn't shipped inside the .app.
    static func bundledModelFolder(for modelID: String) -> String? {
        guard ModelInfo.bundledIDs.contains(modelID),
              let resources = Bundle.main.resourceURL else { return nil }
        let folder = resources
            .appendingPathComponent("BundledModels")
            .appendingPathComponent("openai_whisper-\(modelID)")
        return FileManager.default.fileExists(atPath: folder.path) ? folder.path : nil
    }
}
#endif
