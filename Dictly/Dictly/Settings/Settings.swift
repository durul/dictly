import Foundation
import Combine

@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    let didChange = PassthroughSubject<Void, Never>()

    private enum Keys {
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let hotkeyData = "hotkey.data.v1"
        static let hotkeyMode = "hotkey.mode"
        static let language = "transcription.language"
        static let modelID = "transcription.modelID"
        static let autoInsert = "behavior.autoInsert"
        static let restoreClipboard = "behavior.restoreClipboard"
        static let showHUD = "behavior.showHUD"
        static let hudPosition = "behavior.hudPosition"
        static let llmCleanupEnabled = "postprocess.llm.enabled"
        static let transcriptionQuality = "transcription.quality"
    }

    enum HotkeyMode: String {
        case pushToTalk
        case toggle
    }

    /// Where the recording HUD pill appears on screen.
    enum HUDPosition: String, Sendable {
        /// Bottom-centre of the active screen, ~40 pt above the Dock.
        case bottom
        /// Top of the screen, anchored under the Dictly menu-bar icon. Useful if the
        /// user dictates into apps that have their own bottom controls (Slack, Notes).
        case top
    }

    /// How aggressively Whisper retries a chunk when its first decoding pass
    /// looks degenerate (high compression ratio, low avg logprob, etc.).
    /// Maps directly to `DecodingOptions.temperatureFallbackCount`.
    enum TranscriptionQuality: String, Sendable, CaseIterable {
        /// One greedy pass at temperature 0. Fastest. No recovery if Whisper
        /// gets stuck in a loop on noisy / Bluetooth-warmup audio.
        case fast
        /// Up to one retry at temperature 0.2 if the first pass looks bad.
        /// Default — costs ~1× extra transcribe time only when the recovery
        /// actually triggers, otherwise free.
        case balanced
        /// Up to three retries at progressively higher temperatures. More
        /// chances to escape a bad pass; pays the price (one extra full
        /// transcribe per retry) only when the audio was already going to
        /// produce garbage.
        case best

        /// Value forwarded to WhisperKit's decoder.
        var fallbackCount: Int {
            switch self {
            case .fast:     return 0
            case .balanced: return 1
            case .best:     return 3
            }
        }

        var displayName: String {
            switch self {
            case .fast:     return "Fast"
            case .balanced: return "Balanced"
            case .best:     return "Best quality"
            }
        }
    }

    var didCompleteOnboarding: Bool {
        get { defaults.bool(forKey: Keys.didCompleteOnboarding) }
        set { defaults.set(newValue, forKey: Keys.didCompleteOnboarding); didChange.send() }
    }

    var hotkey: KeyCombo {
        get {
            if let data = defaults.data(forKey: Keys.hotkeyData),
               let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                return combo
            }
            return .defaultHotkey
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.hotkeyData)
                didChange.send()
            }
        }
    }

    var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: Keys.hotkeyMode) ?? "") ?? .pushToTalk }
        set { defaults.set(newValue.rawValue, forKey: Keys.hotkeyMode); didChange.send() }
    }

    /// ISO 639-1 code, or "auto" for Whisper auto-detection.
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "ru" }
        set { defaults.set(newValue, forKey: Keys.language); didChange.send() }
    }

    var modelID: String {
        get {
            var raw = defaults.string(forKey: Keys.modelID) ?? ModelInfo.defaultModelID
            // Migration 1: drop legacy `openai_whisper-` prefix WhisperKit prepends itself.
            if raw.hasPrefix("openai_whisper-") {
                raw = String(raw.dropFirst("openai_whisper-".count))
            }
            // Migration 2: turbo variants on HuggingFace use an underscore (not a hyphen)
            // before "turbo" — `openai_whisper-large-v3_turbo`. Older builds stored the
            // hyphen form which the glob never matched.
            raw = raw.replacingOccurrences(of: "-turbo", with: "_turbo")
            return raw
        }
        set { defaults.set(newValue, forKey: Keys.modelID); didChange.send() }
    }

    var autoInsert: Bool {
        get { (defaults.object(forKey: Keys.autoInsert) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.autoInsert); didChange.send() }
    }

    var restoreClipboard: Bool {
        get { (defaults.object(forKey: Keys.restoreClipboard) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.restoreClipboard); didChange.send() }
    }

    var showHUD: Bool {
        get { (defaults.object(forKey: Keys.showHUD) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.showHUD); didChange.send() }
    }

    var hudPosition: HUDPosition {
        get { HUDPosition(rawValue: defaults.string(forKey: Keys.hudPosition) ?? "") ?? .bottom }
        set { defaults.set(newValue.rawValue, forKey: Keys.hudPosition); didChange.send() }
    }

    /// Reserved for iteration 2 (LLM cleanup).
    var llmCleanupEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmCleanupEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmCleanupEnabled); didChange.send() }
    }

    /// Trade-off between speed and quality of Whisper's decoding. See
    /// `TranscriptionQuality` for the per-preset semantics. Default is
    /// `.balanced` — one retry on degenerate output, otherwise zero cost.
    var transcriptionQuality: TranscriptionQuality {
        get { TranscriptionQuality(rawValue: defaults.string(forKey: Keys.transcriptionQuality) ?? "")
                ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: Keys.transcriptionQuality); didChange.send() }
    }
}
