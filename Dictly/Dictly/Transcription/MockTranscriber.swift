import Foundation

/// A no-op transcriber used in two situations:
/// 1. Before WhisperKit has been added as a Swift package dependency (so the project still builds).
/// 2. Unit / UI testing.
///
/// Returns a placeholder string proportional to the recording length so the rest of the pipeline
/// (HUD, text insertion) can be exercised end-to-end.
final class MockTranscriber: Transcriber, @unchecked Sendable {
    func prepare(modelID: String, progress: @Sendable @MainActor @escaping (Double) -> Void) async throws {
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            await MainActor.run { progress(step) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func transcribe(samples: [Float], language: String, fallbackCount: Int) async throws -> String? {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
        return String(format: "[mock %@ fb=%d] recorded %.1fs of audio",
                      language, fallbackCount, seconds)
    }

    func unload() async {}
}
