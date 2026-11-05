import Foundation

/// One JSON file per execution, so what was cleaned survives the app being closed.
public struct CleanupLog: Codable, Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public let id: String
        public let reason: String
    }

    public let date: Date
    public let module: String
    public let dryRun: Bool
    public let processed: [String]
    public let freedBytes: Int64
    public let failures: [Failure]
    public let log: [String]

    public init(report: ExecutionReport, module: String, dryRun: Bool, date: Date = Date()) {
        self.date = date
        self.module = module
        self.dryRun = dryRun
        processed = report.processed
        freedBytes = report.freedBytes
        failures = report.failures.map { Failure(id: $0.id, reason: $0.reason) }
        log = report.log
    }

    public static let defaultRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/VibeCleaner/Logs")

    /// Writes `<root>/<date> <module>.json` and returns its location.
    @discardableResult
    public func save(in root: URL = CleanupLog.defaultRoot) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: ".")
        var url = root.appendingPathComponent("\(stamp) \(module).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(stamp) \(module) \(n).json")
            n += 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Plain text for the clipboard.
    public var text: String {
        var lines = ["Vibe Cleaner — \(module) — \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(FileSizer.locale)))\(dryRun ? " (simulation)" : "")",
                     "\(processed.count) élément(s) traité(s), \(FileSizer.format(freedBytes)) libérés"]
        lines += log
        if !failures.isEmpty { lines += ["", "Erreurs :"] + failures.map { "\($0.id) — \($0.reason)" } }
        return lines.joined(separator: "\n")
    }
}
