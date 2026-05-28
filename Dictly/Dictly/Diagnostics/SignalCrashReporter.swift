import Foundation
import Darwin

nonisolated
enum SignalCrashReporter {
    nonisolated(unsafe) private static var crashLogFD: Int32 = -1
    nonisolated(unsafe) private static var previousExceptionHandler: NSUncaughtExceptionHandler?
    private static let signalHandler: @convention(c) (Int32) -> Void = { signalNumber in
        SignalCrashReporter.handle(signalNumber: signalNumber)
    }

    private static let handledSignals: [Int32] = [
        SIGABRT,
        SIGBUS,
        SIGFPE,
        SIGILL,
        SIGSEGV,
        SIGTRAP
    ]

    static func install(crashLogURL: URL) {
        try? FileManager.default.createDirectory(at: crashLogURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        crashLogURL.path.withCString { path in
            let fd = Darwin.open(path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
            if fd >= 0 {
                crashLogFD = fd
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            }
        }

        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            SignalCrashReporter.handle(exception: exception)
        }

        for signalNumber in handledSignals {
            Darwin.signal(signalNumber, signalHandler)
        }
    }

    static func handle(exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        let reason = exception.reason ?? "unknown"
        let message = """
        Uncaught NSException name=\(exception.name.rawValue) reason=\(reason)
        \(stack)
        """

        AppDiagnostics.shared.writeSync(level: .fault,
                                        category: "Crash",
                                        message: message,
                                        file: "SignalCrashReporter",
                                        line: 0)
        appendCrashText("\nUncaught NSException name=\(exception.name.rawValue) reason=\(reason)\n\(stack)\n")
        previousExceptionHandler?(exception)
    }

    static func handle(signalNumber: Int32) {
        let fd = crashLogFD
        if fd >= 0 {
            let timestamp = Darwin.time(nil)
            let header = "\nFatal signal \(signalNumber) captured at unix=\(Int64(timestamp)) pid=\(getpid())\n"
            header.withCString { ptr in
                _ = Darwin.write(fd, ptr, strlen(ptr))
            }

            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
            let frameCount = frames.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return 0 }
                return backtrace(base, Int32(buffer.count))
            }
            frames.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress, frameCount > 0 {
                    backtrace_symbols_fd(base, frameCount, fd)
                }
            }

            let footer = "End fatal signal report\n"
            footer.withCString { ptr in
                _ = Darwin.write(fd, ptr, strlen(ptr))
            }
            fsync(fd)
        }

        Darwin.signal(signalNumber, SIG_DFL)
        Darwin.raise(signalNumber)
    }

    private static func appendCrashText(_ text: String) {
        let fd = crashLogFD
        guard fd >= 0 else { return }
        text.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
        fsync(fd)
    }
}
