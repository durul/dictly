import AppKit
import Foundation

/// Side-channel knowledge of WhisperKit's on-disk model layout.
///
/// WhisperKit downloads models into:
///   `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-<id>/`
/// (Sandboxed builds redirect this into the app container.) We don't have a public API to
/// query "is X downloaded" or to delete it, so we touch the filesystem directly.
@MainActor
enum ModelManager {

    private static let log = AppLogger(category: "ModelManager")

    /// Root directory under which all WhisperKit models live for this app.
    static var cacheRoot: URL {
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
    }

    /// Folder name on HuggingFace for a given model variant id.
    static func folderName(for modelID: String) -> String {
        if modelID.hasPrefix("distil-whisper_") {
            return modelID
        }
        return "openai_whisper-\(modelID)"
    }

    static func cacheURL(for modelID: String) -> URL {
        cacheRoot.appendingPathComponent(folderName(for: modelID))
    }

    /// True if the model is shipped with the app or has been downloaded into the cache.
    static func isAvailable(_ modelID: String) -> Bool {
        if ModelInfo.bundledIDs.contains(modelID) { return true }
        return isInCache(modelID)
    }

    /// Backwards-compat alias used by older call sites.
    static func isDownloaded(_ modelID: String) -> Bool { isAvailable(modelID) }

    /// True specifically if the user has a *complete* copy in their Documents/huggingface
    /// cache. We check for the small `coremldata.bin` metadata file in all three of
    /// WhisperKit's CoreML containers — they're the last things written when an
    /// `.mlmodelc` is finalised, so seeing all three means the download finished and the
    /// model is loadable. The previous "directory not empty" fallback was returning
    /// true mid-download (HuggingFace's HubApi creates the folder and starts streaming
    /// blobs into it) which made the UI flip from "Downloading" to "Loading from cache"
    /// half-way through.
    static func isInCache(_ modelID: String) -> Bool {
        let folder = cacheURL(for: modelID)
        let fm = FileManager.default
        let required = ["AudioEncoder", "TextDecoder", "MelSpectrogram"]
        return required.allSatisfy { sub in
            let path = folder
                .appendingPathComponent("\(sub).mlmodelc")
                .appendingPathComponent("coremldata.bin").path
            return fm.fileExists(atPath: path)
        }
    }

    /// IDs that are *available right now* — bundled with the app or already in cache.
    /// Walks the on-disk cache directly so it picks up anything the user has, even
    /// variants that aren't (yet) in the live HuggingFace catalog snapshot.
    static func availableIDs() -> Set<String> {
        var ids = ModelInfo.bundledIDs
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: cacheRoot,
                                                          includingPropertiesForKeys: nil)
        else { return ids }
        for url in contents {
            let name = url.lastPathComponent
            // WhisperKit puts every variant inside `openai_whisper-<id>`.
            guard name.hasPrefix("openai_whisper-") else { continue }
            let id = String(name.dropFirst("openai_whisper-".count))
            if isInCache(id) { ids.insert(id) }
        }
        return ids
    }

    /// Backwards-compat alias.
    static func downloadedIDs() -> Set<String> { availableIDs() }

    /// Disk usage for a given model (sum of all files in the folder), nil if not present.
    static func diskUsageBytes(for modelID: String) -> Int64? {
        let url = cacheURL(for: modelID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var total: Int64 = 0
        if let it = FileManager.default.enumerator(at: url,
                                                    includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in it {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    /// Deletes the model from disk so the user can free space.
    /// Bundled models can't be deleted — they live read-only inside the .app.
    static func delete(_ modelID: String) throws {
        if ModelInfo.bundledIDs.contains(modelID) { return }
        let url = cacheURL(for: modelID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        log.info("Deleted model \(modelID)")
    }

    static func reveal(_ modelID: String) {
        let url = cacheURL(for: modelID)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(cacheRoot)
        }
    }
}
