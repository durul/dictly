import Foundation

nonisolated
final class RotatingLocalLog: @unchecked Sendable {
    let directory: URL
    let logURL: URL
    let crashLogURL: URL
    let metricKitDirectory: URL

    private let queue = DispatchQueue(label: "com.mydear.voicetotext.local-log")
    private let maxLogBytes: UInt64 = 2 * 1024 * 1024
    private let maxArchiveCount = 5

    init(fileManager: FileManager = .default) {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        self.directory = library.appendingPathComponent("Logs").appendingPathComponent(DiagnosticsConstants.appName)
        self.logURL = directory.appendingPathComponent("Dictly.log")
        self.crashLogURL = directory.appendingPathComponent("Dictly-crash.log")
        self.metricKitDirectory = directory.appendingPathComponent("MetricKit")
    }

    func prepare() {
        queue.sync {
            createDirectories()
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            if !FileManager.default.fileExists(atPath: crashLogURL.path) {
                FileManager.default.createFile(atPath: crashLogURL.path, contents: nil)
            }
        }
    }

    func write(level: AppLogLevel,
               category: String,
               message: String,
               file: String,
               line: UInt) {
        let entry = LogEntry(date: Date(),
                             level: level,
                             category: category,
                             message: message,
                             file: file,
                             line: line)
        queue.async { [self] in
            append(entry)
        }
    }

    func writeSync(level: AppLogLevel,
                   category: String,
                   message: String,
                   file: String,
                   line: UInt) {
        let entry = LogEntry(date: Date(),
                             level: level,
                             category: category,
                             message: message,
                             file: file,
                             line: line)
        queue.sync {
            append(entry)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func append(_ entry: LogEntry) {
        createDirectories()
        let line = format(entry)
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded(additionalBytes: UInt64(data.count))
        append(data, to: logURL)
    }

    private func createDirectories() {
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metricKitDirectory,
                                                 withIntermediateDirectories: true)
    }

    private func rotateIfNeeded(additionalBytes: UInt64) {
        let currentSize = fileSize(logURL)
        guard currentSize + additionalBytes > maxLogBytes else { return }

        let fm = FileManager.default
        let oldest = rotatedURL(index: maxArchiveCount)
        if fm.fileExists(atPath: oldest.path) {
            try? fm.removeItem(at: oldest)
        }

        if maxArchiveCount > 1 {
            for index in stride(from: maxArchiveCount - 1, through: 1, by: -1) {
                let source = rotatedURL(index: index)
                let destination = rotatedURL(index: index + 1)
                if fm.fileExists(atPath: source.path) {
                    try? fm.moveItem(at: source, to: destination)
                }
            }
        }

        if fm.fileExists(atPath: logURL.path) {
            try? fm.moveItem(at: logURL, to: rotatedURL(index: 1))
        }
        fm.createFile(atPath: logURL.path, contents: nil)
    }

    private func append(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    private func rotatedURL(index: Int) -> URL {
        directory.appendingPathComponent("Dictly.\(index).log")
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private func format(_ entry: LogEntry) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: entry.date)
        let pid = ProcessInfo.processInfo.processIdentifier
        return "\(timestamp) [\(pid)] \(entry.level.rawValue) \(entry.category) \(entry.file):\(entry.line) \(entry.message)\n"
    }
}

private struct LogEntry {
    let date: Date
    let level: AppLogLevel
    let category: String
    let message: String
    let file: String
    let line: UInt
}
