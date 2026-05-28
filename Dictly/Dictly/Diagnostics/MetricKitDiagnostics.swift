import Foundation
@preconcurrency import MetricKit

nonisolated
final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let log = AppLogger(category: "MetricKit")
    private let queue = DispatchQueue(label: "com.mydear.voicetotext.metric-kit")
    private var outputDirectory: URL?
    private let maxPayloadFiles = 30

    func start(outputDirectory: URL) {
        queue.sync {
            self.outputDirectory = outputDirectory
            try? FileManager.default.createDirectory(at: outputDirectory,
                                                     withIntermediateDirectories: true)
        }

        MXMetricManager.shared.add(self)

        let manager = MXMetricManager.shared
        if !manager.pastDiagnosticPayloads.isEmpty {
            log.notice("MetricKit past diagnostic payloads available: \(manager.pastDiagnosticPayloads.count)")
            writeDiagnosticPayloads(manager.pastDiagnosticPayloads, source: "past")
        }
        if !manager.pastPayloads.isEmpty {
            log.notice("MetricKit past metric payloads available: \(manager.pastPayloads.count)")
            writeMetricPayloads(manager.pastPayloads, source: "past")
        }
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        log.notice("MetricKit diagnostic payloads received: \(payloads.count)")
        writeDiagnosticPayloads(payloads, source: "received")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        log.notice("MetricKit metric payloads received: \(payloads.count)")
        writeMetricPayloads(payloads, source: "received")
    }

    private func writeDiagnosticPayloads(_ payloads: [MXDiagnosticPayload], source: String) {
        let records = payloads.enumerated().map { index, payload in
            DiagnosticPayloadRecord(
                data: payload.jsonRepresentation(),
                filename: payloadFilename(prefix: "diagnostic",
                                          source: source,
                                          begin: payload.timeStampBegin,
                                          end: payload.timeStampEnd,
                                          index: index),
                crashes: payload.crashDiagnostics?.count ?? 0,
                hangs: payload.hangDiagnostics?.count ?? 0,
                cpu: payload.cpuExceptionDiagnostics?.count ?? 0,
                disk: payload.diskWriteExceptionDiagnostics?.count ?? 0
            )
        }

        queue.async { [self] in
            guard let outputDirectory else { return }
            for record in records {
                let url = outputDirectory.appendingPathComponent(record.filename)
                write(record.data, to: url)
                log.notice("MetricKit diagnostic saved: \(url.path) crashes=\(record.crashes) hangs=\(record.hangs) cpu=\(record.cpu) disk=\(record.disk)")
            }
            prunePayloadFiles(prefix: "diagnostic-", in: outputDirectory)
        }
    }

    private func writeMetricPayloads(_ payloads: [MXMetricPayload], source: String) {
        let records = payloads.enumerated().map { index, payload in
            MetricPayloadRecord(
                data: payload.jsonRepresentation(),
                filename: payloadFilename(prefix: "metric",
                                          source: source,
                                          begin: payload.timeStampBegin,
                                          end: payload.timeStampEnd,
                                          index: index)
            )
        }

        queue.async { [self] in
            guard let outputDirectory else { return }
            for record in records {
                let url = outputDirectory.appendingPathComponent(record.filename)
                write(record.data, to: url)
                log.info("MetricKit metric saved: \(url.path)")
            }
            prunePayloadFiles(prefix: "metric-", in: outputDirectory)
        }
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("MetricKit payload write failed: \(url.path) error=\(error.localizedDescription)")
        }
    }

    private func payloadFilename(prefix: String,
                                 source: String,
                                 begin: Date,
                                 end: Date,
                                 index: Int) -> String {
        let beginSeconds = Int(begin.timeIntervalSince1970)
        let endSeconds = Int(end.timeIntervalSince1970)
        return "\(prefix)-\(source)-\(beginSeconds)-\(endSeconds)-\(index).json"
    }

    private func prunePayloadFiles(prefix: String, in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        let matching = urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }

        guard matching.count > maxPayloadFiles else { return }
        for url in matching.dropFirst(maxPayloadFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private struct DiagnosticPayloadRecord: Sendable {
    let data: Data
    let filename: String
    let crashes: Int
    let hangs: Int
    let cpu: Int
    let disk: Int
}

private struct MetricPayloadRecord: Sendable {
    let data: Data
    let filename: String
}
