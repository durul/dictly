import Foundation

/// Single seam between the rest of the app and the chosen STT backend.
/// When WhisperKit is added as a dependency, the real implementation is selected
/// automatically via `#if canImport(WhisperKit)`.
enum TranscriberFactory {
    static func make() -> Transcriber {
        #if canImport(WhisperKit)
        return WhisperKitTranscriber()
        #else
        return MockTranscriber()
        #endif
    }

    static var isUsingMock: Bool {
        #if canImport(WhisperKit)
        return false
        #else
        return true
        #endif
    }
}
