import Foundation

/// State of XProtect, the malware scanner built into macOS, read with Apple's `xprotect` tool (macOS 15+).
/// XProtect checks apps at launch and scans the Mac in the background on its own: Vibe Cleaner only shows it.
public struct XProtectStatus: Sendable, Hashable {
    public var launchScans: Bool
    public var backgroundScans: Bool
    /// Version of the signatures, e.g. "5368".
    public var version: String?
    /// When those signatures were installed.
    public var installed: Date?

    public var isActive: Bool { launchScans && backgroundScans }

    public init(launchScans: Bool, backgroundScans: Bool, version: String? = nil, installed: Date? = nil) {
        self.launchScans = launchScans
        self.backgroundScans = backgroundScans
        self.version = version
        self.installed = installed
    }

    static let tool = "/usr/bin/xprotect"

    /// Nil when the tool is missing or answers nothing usable. Read-only, no prompt.
    public static func read() -> XProtectStatus? {
        guard FileManager.default.isExecutableFile(atPath: tool),
              let status = FileScan.capture(tool, ["status"], timeout: 10, abort: { false }) else { return nil }
        let version = FileScan.capture(tool, ["version"], timeout: 10, abort: { false }) ?? ""
        return parse(status: status, version: version)
    }

    /// `status`: "XProtect launch scans: enabled" / "XProtect background scans: enabled".
    /// `version`: "Version: 5368 Installed: 2026-10-22 18:02:23 +0000".
    static func parse(status: String, version: String) -> XProtectStatus? {
        func flag(_ key: String) -> Bool? {
            guard let line = status.split(whereSeparator: \.isNewline).first(where: { $0.localizedCaseInsensitiveContains(key) }) else { return nil }
            return line.lowercased().hasSuffix("enabled")
        }
        guard let launch = flag("launch scans"), let background = flag("background scans") else { return nil }
        var s = XProtectStatus(launchScans: launch, backgroundScans: background)
        if let v = version.range(of: #"Version:\s*(\S+)"#, options: .regularExpression) {
            s.version = version[v].split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        }
        if let i = version.range(of: "Installed:") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            s.installed = f.date(from: version[i.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return s
    }
}
