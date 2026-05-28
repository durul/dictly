import Foundation
import OSLog

nonisolated
enum DiagnosticsConstants {
    static let subsystem = "com.mydear.voicetotext"
    static let appName = "Dictly"
}

nonisolated
enum AppLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case error = "ERROR"
    case fault = "FAULT"
}

nonisolated
struct AppLogger: Sendable {
    private let category: String
    private let osLogger: Logger

    init(category: String) {
        self.category = category
        self.osLogger = Logger(subsystem: DiagnosticsConstants.subsystem, category: category)
    }

    func debug(_ message: @autoclosure () -> String,
               file: StaticString = #fileID,
               line: UInt = #line) {
        log(.debug, message(), file: file, line: line)
    }

    func info(_ message: @autoclosure () -> String,
              file: StaticString = #fileID,
              line: UInt = #line) {
        log(.info, message(), file: file, line: line)
    }

    func notice(_ message: @autoclosure () -> String,
                file: StaticString = #fileID,
                line: UInt = #line) {
        log(.notice, message(), file: file, line: line)
    }

    func error(_ message: @autoclosure () -> String,
               file: StaticString = #fileID,
               line: UInt = #line) {
        log(.error, message(), file: file, line: line)
    }

    func fault(_ message: @autoclosure () -> String,
               file: StaticString = #fileID,
               line: UInt = #line) {
        log(.fault, message(), file: file, line: line)
    }

    private func log(_ level: AppLogLevel,
                     _ message: String,
                     file: StaticString,
                     line: UInt) {
        switch level {
        case .debug:
            osLogger.debug("\(message, privacy: .public)")
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .notice:
            osLogger.notice("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        case .fault:
            osLogger.fault("\(message, privacy: .public)")
        }

        AppDiagnostics.shared.write(level: level,
                                    category: category,
                                    message: message,
                                    file: String(describing: file),
                                    line: line)
    }
}

nonisolated
final class AppDiagnostics: @unchecked Sendable {
    static let shared = AppDiagnostics()

    let localLog = RotatingLocalLog()

    private let lifecycleLock = NSLock()
    private var isStarted = false

    private init() {}

    var logURL: URL { localLog.logURL }

    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isStarted else { return }
        isStarted = true

        localLog.prepare()

        writeRuntimeHeader()
    }

    func stop() {
        write(level: .notice,
              category: "Diagnostics",
              message: "Application will terminate",
              file: "AppDiagnostics",
              line: 0)
        localLog.flush()
    }

    func write(level: AppLogLevel,
               category: String,
               message: String,
               file: String,
               line: UInt) {
        localLog.write(level: level,
                       category: category,
                       message: message,
                       file: file,
                       line: line)
    }

    func writeSync(level: AppLogLevel,
                   category: String,
                   message: String,
                   file: String,
                   line: UInt) {
        localLog.writeSync(level: level,
                           category: category,
                           message: message,
                           file: file,
                           line: line)
    }

    private func writeRuntimeHeader() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let pid = ProcessInfo.processInfo.processIdentifier

        writeSync(level: .notice,
                  category: "Diagnostics",
                  message: "Diagnostics started; version=\(version) build=\(build) pid=\(pid) os=\(os) log=\(logURL.path)",
                  file: "AppDiagnostics",
                  line: 0)
    }
}
