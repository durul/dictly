import Foundation

/// Abstract STT backend. Today: WhisperKit. Tomorrow: anything we want to swap in.
///
/// Inputs are 16 kHz mono Float32 PCM samples. The implementation is responsible for
/// any chunking required by the underlying model.
protocol Transcriber: Sendable {
    /// Loads model files from disk (downloading if needed) and prepares for inference.
    /// Calling repeatedly is a no-op once a matching model is loaded.
    func prepare(modelID: String, progress: @Sendable @MainActor @escaping (Double) -> Void) async throws

    /// Returns the recognized text for the given samples, or `nil` if speech wasn't detected.
    /// `language` is an ISO 639-1 code or "auto".
    /// `fallbackCount` is the maximum number of decoder retries (with bumped
    /// temperatures) when the first greedy pass produces a degenerate result.
    /// 0 = no retries (fastest), 1 = one safety-net retry, 3 = aggressive.
    func transcribe(samples: [Float], language: String, fallbackCount: Int) async throws -> String?

    /// Discards loaded model weights and frees memory.
    func unload() async
}

enum TranscriberError: Error, LocalizedError {
    case modelNotLoaded
    case backendUnavailable
    case empty

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Model not loaded."
        case .backendUnavailable: return "STT backend not available in this build."
        case .empty: return "No speech detected."
        }
    }
}
