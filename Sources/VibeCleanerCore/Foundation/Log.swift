import Foundation
import os

/// Technical log: always to the unified log, and also to a text file while
/// "Journaux détaillés" is on (the app sets `Log.file.directory`). Separate from `CleanupLog`.
public struct Log: Sendable {
    public static let subsystem = "ai.flowpace.vibecleaner"
    public static let file = LogFile()

    let category: String
    private let logger: Logger

    public init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: String) { write(.debug, message) }
    public func info(_ message: String) { write(.info, message) }
    public func error(_ message: String) { write(.error, message) }

    /// Messages carry paths, URLs and names from the disk: private in the unified log (readable on this Mac only
    /// with a logging profile), one line each in the file.
    private func write(_ level: OSLogType, _ message: String) {
        let text = LogFile.oneLine(LogFile.anonymized(message))
        logger.log(level: level, "\(text, privacy: .private)")
        Self.file.append(level: level, category: category, text)
    }
}

/// Plain text file `vibecleaner.log` in `directory`; nil (the default) writes nothing.
public final class LogFile: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VibeCleaner")
    }
    /// Past this size the file starts over, which keeps it bounded without rotation.
    static let maxBytes = 5_000_000
    private let state = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public init() {}

    public var directory: URL? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    public var url: URL? { directory?.appendingPathComponent("vibecleaner.log") }

    func append(level: OSLogType, category: String, _ message: String, date: Date = Date()) {
        state.withLock { dir in
            guard let dir else { return }
            let url = dir.appendingPathComponent("vibecleaner.log")
            let name = switch level { case .debug: "debug"; case .error, .fault: "error"; default: "info" }
            let line = Data("\(date.ISO8601Format()) [\(name)] [\(Self.oneLine(category))] \(Self.oneLine(message))\n".utf8)
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0, size < Self.maxBytes, let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
                try? h.close()
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    /// Control characters (line breaks above all) become visible marks, so a file name can't forge a log line.
    static func oneLine(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" ? "␤" : (($0.value < 0x20 && $0 != "\t") || (0x7F...0x9F).contains($0.value) ? "�" : $0) }))
    }

    /// Hides the user name in `/Users/<name>/`.
    static func anonymized(_ s: String, home: String = NSHomeDirectory()) -> String {
        home.isEmpty || home == "/" ? s : s.replacingOccurrences(of: home, with: "~")
    }
}
