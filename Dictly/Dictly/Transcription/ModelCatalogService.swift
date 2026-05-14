import Foundation
import Combine
import OSLog

/// Loads the WhisperKit model catalog from HuggingFace.
///
/// The only hardcoded entries are `ModelInfo.bundledEntries` (our offline-ready models).
/// Every other variant is parsed from the `argmaxinc/whisperkit-coreml`
/// repo tree:
///   • folder name → `id` (after stripping the `openai_whisper-` prefix)
///   • sum of file sizes within the folder → `approximateSizeMB`
///   • latest commit date among the folder's files → `lastModified`
///
/// The result is cached in `UserDefaults` so we can surface a list immediately
/// on subsequent launches — even offline. The live fetch runs in the
/// background and replaces the cached snapshot when it completes.
@MainActor
final class ModelCatalogService {

    static let shared = ModelCatalogService()

    private static let log = Logger(subsystem: "com.mydear.voicetotext", category: "ModelCatalog")

    /// Live published model list. Bundled model(s) are always first.
    let models = CurrentValueSubject<[ModelInfo], Never>(ModelInfo.bundledEntries)
    let isLoading = CurrentValueSubject<Bool, Never>(false)
    let lastError = CurrentValueSubject<String?, Never>(nil)
    let lastRefreshAt = CurrentValueSubject<Date?, Never>(nil)

    private let cacheKey = "modelCatalog.v1"
    private let cacheDateKey = "modelCatalog.v1.date"
    private var refreshTask: Task<Void, Never>?

    private init() {
        loadFromCache()
        refresh()
    }

    /// Kick off a background fetch from HuggingFace. Cancels any in-flight one.
    func refresh() {
        refreshTask?.cancel()
        isLoading.send(true)
        lastError.send(nil)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let remote = try await Self.fetchFromHuggingFace()
                if Task.isCancelled { return }
                self.merge(remote)
                self.isLoading.send(false)
                self.lastRefreshAt.send(Date())
            } catch is CancellationError {
                // Newer task took over.
                return
            } catch {
                if Task.isCancelled { return }
                Self.log.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
                self.lastError.send(error.localizedDescription)
                self.isLoading.send(false)
            }
        }
    }

    private func merge(_ remote: [ModelInfo]) {
        var list = ModelInfo.bundledEntries
        let nonBundled = remote.filter { !ModelInfo.bundledIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let lt = Self.tierOrder(lhs.tier)
                let rt = Self.tierOrder(rhs.tier)
                if lt != rt { return lt < rt }
                // Within tier: most recently updated first.
                return (lhs.lastModified ?? .distantPast) > (rhs.lastModified ?? .distantPast)
            }
        list += nonBundled
        models.send(list)
        saveToCache(list)
    }

    private static func tierOrder(_ tier: ModelInfo.Tier) -> Int {
        switch tier {
        case .tiny:   return 0
        case .small:  return 1
        case .medium: return 2
        case .large:  return 3
        }
    }

    // MARK: - Cache

    private func loadFromCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode([ModelInfo].self, from: data) else { return }
        var list = ModelInfo.bundledEntries
        list += cached.filter { !ModelInfo.bundledIDs.contains($0.id) }
        models.send(list)
        if let date = UserDefaults.standard.object(forKey: cacheDateKey) as? Date {
            lastRefreshAt.send(date)
        }
    }

    private func saveToCache(_ list: [ModelInfo]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(list) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        }
    }

    // MARK: - HuggingFace fetch

    /// Recursive tree listing with `expand=true` returns each file's size and
    /// each entry's `lastCommit`. The HF tree endpoint paginates at 100 entries
    /// per page (limit=100 is the maximum it accepts), with the next page URL
    /// supplied in a `Link: <…>; rel="next"` header. We follow the cursor until
    /// the chain ends, then group every file path by its top-level
    /// `openai_whisper-*` folder.
    private static let firstPageURL = URL(string:
        "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main?recursive=true&expand=true&limit=100")!

    private static func fetchFromHuggingFace() async throws -> [ModelInfo] {
        var entries: [HFTreeEntry] = []
        var nextURL: URL? = firstPageURL
        // Hard cap so a malformed Link cursor can't loop us forever.
        var pageCount = 0
        let maxPages = 30
        while let url = nextURL, pageCount < maxPages {
            pageCount += 1
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "ModelCatalog", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey:
                                         "HTTP \(http.statusCode) from HuggingFace"])
            }
            let page = try Self.decoder.decode([HFTreeEntry].self, from: data)
            entries.append(contentsOf: page)
            nextURL = http.value(forHTTPHeaderField: "Link").flatMap(Self.parseNextLink)
        }

        var byFolder: [String: (size: Int64, latest: Date?)] = [:]
        for entry in entries {
            let firstSlash = entry.path.firstIndex(of: "/")
            let topName = firstSlash.map { String(entry.path[..<$0]) } ?? entry.path
            guard topName.hasPrefix("openai_whisper-") else { continue }

            var agg = byFolder[topName] ?? (0, nil)
            if entry.type == "file", let size = entry.size {
                agg.size += size
            }
            if let date = entry.lastCommit?.date {
                if let prev = agg.latest {
                    if date > prev { agg.latest = date }
                } else {
                    agg.latest = date
                }
            }
            byFolder[topName] = agg
        }

        return byFolder.compactMap { folder, agg -> ModelInfo? in
            let id = String(folder.dropFirst("openai_whisper-".count))
            // Skip any bundled ones — we always serve our hardcoded copies.
            if ModelInfo.bundledIDs.contains(id) { return nil }
            return ModelInfo(
                id: id,
                displayName: ModelInfo.deriveDisplayName(from: id),
                approximateSizeMB: agg.size > 0 ? Int(agg.size / (1024 * 1024)) : nil,
                multilingual: !id.contains(".en"),
                tier: ModelInfo.deriveTier(from: id),
                lastModified: agg.latest,
                notes: ""
            )
        }
    }

    /// Pulls the URL out of an RFC-5988 `Link` header value where the
    /// `rel="next"` reference points. Returns nil if there's no next link.
    private static func parseNextLink(_ header: String) -> URL? {
        for part in header.components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("rel=\"next\"") else { continue }
            guard let lt = trimmed.firstIndex(of: "<"),
                  let gt = trimmed[lt...].firstIndex(of: ">"),
                  gt > lt else { continue }
            let urlStr = String(trimmed[trimmed.index(after: lt)..<gt])
            return URL(string: urlStr)
        }
        return nil
    }

    /// HF returns dates in ISO-8601 with or without fractional seconds depending
    /// on the field. Try both. Formatters are built lazily inside the closure
    /// because `ISO8601DateFormatter` isn't `Sendable` and the strategy closure
    /// is `@Sendable`.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let isoFractional = ISO8601DateFormatter()
            isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let dt = isoFractional.date(from: str) { return dt }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let dt = iso.date(from: str) { return dt }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unrecognised date string: \(str)")
        }
        return d
    }()

    // MARK: - HF tree entry shapes

    private struct HFTreeEntry: Decodable {
        let path: String
        let type: String           // "file" | "directory"
        let size: Int64?
        let lastCommit: HFCommit?
    }

    private struct HFCommit: Decodable {
        let id: String?
        let title: String?
        let date: Date?
    }
}
