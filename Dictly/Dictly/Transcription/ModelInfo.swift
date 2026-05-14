import Foundation
import Combine

/// Whisper model variant. Most fields are filled in from the live HuggingFace
/// catalog (`ModelCatalogService`); the only hardcoded entry is `bundled`.
///
/// `id` is the WhisperKit variant identifier — the suffix after `openai_whisper-`
/// in the HuggingFace folder name. WhisperKit prepends `openai_*` itself, so we
/// pass only the suffix. (Note: turbo uses an UNDERSCORE before `turbo`,
/// e.g. `large-v3_turbo`.)
struct ModelInfo: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let displayName: String
    /// Approximate compressed download size. `nil` while the size is unknown
    /// (e.g. before the first remote refresh has completed for a new variant).
    let approximateSizeMB: Int?
    let multilingual: Bool
    let tier: Tier
    /// Latest commit date for the model's folder in the HF repo. `nil` for the
    /// bundled model (we use the literal training-date stamp encoded in the id).
    let lastModified: Date?
    /// Hand-curated note (only set for the bundled model). HF-fetched entries
    /// leave this empty.
    let notes: String

    enum Tier: String, Sendable, Codable {
        case tiny      // smallest / fastest / lowest accuracy
        case small     // decent balance
        case medium    // high quality, noticeable load
        case large     // max quality, heaviest
    }

    /// True if this model's files are pre-shipped inside the application bundle.
    var isBundled: Bool { Self.bundledIDs.contains(id) }

    /// Models we ship inside the .app bundle. `WhisperKitTranscriber` points
    /// `modelFolder` directly at the bundle path for these — no download needed.
    ///
    /// Two-tier setup so the same source builds two flavours of the app:
    ///   • **Internal / direct** build ships `large-v3-v20240930_547MB`
    ///     (highest quality, ~547 MB).
    ///   • **Public GitHub** build ships only `base` (~139 MB) — large-v3 has
    ///     one file (TextDecoder weights) right under GitHub's 100 MB per-file
    ///     limit, so the public mirror prunes it via `sync_to_public.sh`.
    /// Both IDs are listed here; `bundledModelFolder()` falls through to nil
    /// when the on-disk folder is missing, so unused entries are harmless.
    nonisolated static let bundledIDs: Set<String> = [
        "large-v3-v20240930_547MB",
        "base"
    ]

    /// First-launch model. Picks the highest-quality variant that's *actually*
    /// present in the .app bundle, falling back through the preferences list.
    /// Lets the public build (only `base` bundled) start offline without ever
    /// touching the network, while the internal build still picks large-v3 by
    /// default — same source, no build-flag plumbing required.
    static var defaultModelID: String {
        let preference = ["large-v3-v20240930_547MB", "base"]
        if let resources = Bundle.main.resourceURL {
            for id in preference {
                let folder = resources
                    .appendingPathComponent("BundledModels")
                    .appendingPathComponent("openai_whisper-\(id)")
                if FileManager.default.fileExists(atPath: folder.path) {
                    return id
                }
            }
        }
        return preference.last!
    }

    /// Hardcoded entries for whichever bundled model(s) are *actually present*
    /// in the .app at runtime. Returned in priority order (largest first).
    /// `ModelCatalogService` prepends these to the live HuggingFace catalog so
    /// they always appear even before the first network refresh.
    static var bundledEntries: [ModelInfo] {
        var entries: [ModelInfo] = []
        if hasPhysicalBundle(id: "large-v3-v20240930_547MB") {
            entries.append(ModelInfo(
                id: "large-v3-v20240930_547MB",
                displayName: "Large v3 · compressed",
                approximateSizeMB: 547,
                multilingual: true,
                tier: .large,
                lastModified: ISO8601DateFormatter().date(from: "2024-09-30T00:00:00Z"),
                notes: "Bundled with Dictly — works offline."
            ))
        }
        if hasPhysicalBundle(id: "base") {
            entries.append(ModelInfo(
                id: "base",
                displayName: "Base · multilingual",
                approximateSizeMB: 139,
                multilingual: true,
                tier: .small,
                lastModified: nil,
                notes: "Bundled with Dictly — works offline."
            ))
        }
        return entries
    }

    private static func hasPhysicalBundle(id: String) -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let folder = resources
            .appendingPathComponent("BundledModels")
            .appendingPathComponent("openai_whisper-\(id)")
        return FileManager.default.fileExists(atPath: folder.path)
    }

    /// Lookup helper. Searches the live catalog (which always contains `bundled`).Алло, алло, алло.
    @MainActor
    static func info(for id: String) -> ModelInfo? {
        ModelCatalogService.shared.models.value.first { $0.id == id }
    }
}

// MARK: - Display-name & tier inference (used by ModelCatalogService when it
// turns a HuggingFace folder name into a `ModelInfo`).

extension ModelInfo {
    /// Turn a variant id like `large-v3_turbo_954MB` into `Large v3 Turbo (954 MB)`.
    nonisolated static func deriveDisplayName(from id: String) -> String {
        var base = id

        // Pull off a trailing size annotation first ("_547MB", "_954MB", …) so
        // a `.en` token immediately before it is still detectable.
        var sizeSuffix: String?
        if let r = base.range(of: #"_\d+MB$"#, options: .regularExpression) {
            sizeSuffix = String(base[r].dropFirst())   // "547MB"
            base.removeSubrange(r)
        }

        let isEnglish = base.hasSuffix(".en")
        if isEnglish { base.removeLast(".en".count) }

        // Tokenise on '-' / '_' and Title-Case each token.
        var tokens: [String] = []
        var token = ""
        for ch in base {
            if ch == "-" || ch == "_" {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(ch)
            }
        }
        if !token.isEmpty { tokens.append(token) }

        let titled = tokens.map(formatToken).joined(separator: " ")
        var result = titled
        if isEnglish { result += " · English" }
        if let sz = sizeSuffix { result += " (\(sz))" }
        return result
    }

    nonisolated private static func formatToken(_ t: String) -> String {
        // "v2", "v3", "v20240930" pass through.
        if t.range(of: #"^v\d"#, options: .regularExpression) != nil { return t }
        if t == "turbo"  { return "Turbo" }
        if t == "distil" { return "Distil" }
        guard let first = t.first else { return t }
        return String(first).uppercased() + t.dropFirst()
    }

    /// Crude tier classifier — by id prefix.
    nonisolated static func deriveTier(from id: String) -> Tier {
        if id.hasPrefix("tiny")   { return .tiny }
        if id.hasPrefix("base")   { return .small }
        if id.hasPrefix("small")  { return .small }
        if id.hasPrefix("medium") { return .medium }
        return .large
    }
}

/// Whisper supported languages, popular subset surfaced in UI. Code is ISO 639-1.
struct LanguageOption: Hashable, Sendable {
    let code: String
    let displayName: String

    static let auto = LanguageOption(code: "auto", displayName: "Auto-detect")

    static let popular: [LanguageOption] = [
        .auto,
        LanguageOption(code: "ru", displayName: "Русский"),
        LanguageOption(code: "en", displayName: "English"),
        LanguageOption(code: "uk", displayName: "Українська"),
        LanguageOption(code: "es", displayName: "Español"),
        LanguageOption(code: "de", displayName: "Deutsch"),
        LanguageOption(code: "fr", displayName: "Français"),
        LanguageOption(code: "it", displayName: "Italiano"),
        LanguageOption(code: "pt", displayName: "Português"),
        LanguageOption(code: "pl", displayName: "Polski"),
        LanguageOption(code: "tr", displayName: "Türkçe"),
        LanguageOption(code: "zh", displayName: "中文"),
        LanguageOption(code: "ja", displayName: "日本語"),
        LanguageOption(code: "ko", displayName: "한국어"),
        LanguageOption(code: "ar", displayName: "العربية"),
        LanguageOption(code: "hi", displayName: "हिन्दी")
    ]
}
