import Foundation

/// Everything a Cleanup scanner needs. Home paths always derive from `context.home` so tests can use a fake home.
struct JunkScope: Sendable {
    let context: ModuleContext
    /// False in tests: skips everything outside the home (/Library, /private, /Volumes, darwin dirs, xcrun, brew).
    let system: Bool
    /// Lowercased bundle ids and names of running apps.
    let running: Set<String>

    var home: URL { context.home }
    func h(_ path: String) -> URL { home.appendingPathComponent(path) }
    func lib(_ path: String) -> URL { home.appendingPathComponent("Library").appendingPathComponent(path) }

    func isRunning(_ name: String) -> Bool { running.contains(name.lowercased()) }

    /// A folder name rarely matches the running app: a cache written in the last 10 minutes is treated as in use.
    static let inUseWindow: TimeInterval = 10 * 60

    /// Modified in the last `window`: the item itself or one of its direct children (the whole tree would cost too much).
    func recentlyModified(_ url: URL, window: TimeInterval = inUseWindow, now: Date = Date()) -> Bool {
        let dates = [Junk.modified(url)] + Junk.children(url, hidden: true).map(Junk.modified)
        return dates.contains { $0.map { now.timeIntervalSince($0) < window } ?? false }
    }

    /// Root-owned items need the admin batch: anything outside the home, and root-owned folders inside it.
    func needsAdmin(_ url: URL) -> Bool {
        guard Junk.isRootOwned(url) else { return false }
        let inHome = [home.path, Junk.realPath(home.path)].contains { url.path.hasPrefix($0 + "/") }
        return !inHome || Junk.isDirectory(url)
    }

    /// A deletable item, or nil when excluded or empty.
    func item(_ url: URL, name: String? = nil, detail: String? = nil, mode: RemovalMode, auto: Bool = true,
              keepEmpty: Bool = false, size: Int64? = nil) -> ResultItem? {
        if context.isExcluded(url) { return nil }
        let size = size ?? FileSizer.size(of: url)
        if size == 0 && !keepEmpty { return nil }
        // Root work is never selected by default: it asks for the administrator password.
        let admin = needsAdmin(url)
        return ResultItem(name: name ?? url.lastPathComponent, detail: detail ?? url.deletingLastPathComponent().path, url: url,
                          size: size, date: Junk.modified(url), action: .delete(url, mode: mode, admin: admin),
                          autoSelect: auto && !admin)
    }
}

enum Junk {
    static var fm: FileManager { .default }

    /// Children of a folder (one level), without `.DS_Store`. Hidden entries only when asked.
    static func children(_ url: URL, hidden: Bool = false) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
        let list = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: opts)) ?? []
        return list.filter { $0.lastPathComponent != ".DS_Store" }
    }

    /// realpath(3): unlike `resolvingSymlinksInPath`, keeps the /private prefix that directory listings return.
    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    static func isRootOwned(_ url: URL) -> Bool {
        ((try? fm.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber)?.intValue == 0
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func created(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Expands `*` path segments (fnmatch) under a root, e.g. "Group Containers/*.Telegram/*/media".
    static func glob(_ root: URL, _ pattern: String) -> [URL] {
        var current = [root]
        for segment in pattern.split(separator: "/").map(String.init) {
            if segment.contains("*") {
                current = current.flatMap { dir in
                    children(dir, hidden: true).filter { fnmatch(segment, $0.lastPathComponent, 0) == 0 }
                }
            } else {
                current = current.map { $0.appendingPathComponent(segment) }.filter(exists)
            }
        }
        return current
    }

    static func confstrPath(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// User apps: /Applications (system scope) and ~/Applications, first level only.
    static func applications(_ scope: JunkScope) -> [URL] {
        var roots = [scope.h("Applications")]
        if scope.system { roots.insert(URL(fileURLWithPath: "/Applications"), at: 0) }
        return roots.flatMap { children($0) }.filter { $0.pathExtension == "app" && !scope.context.isExcluded($0) }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func format(_ date: Date?) -> String { date.map(dateFormatter.string(from:)) ?? "date inconnue" }
}

/// Built-in ignore rules: caches and logs that must stay, written by hand.
enum DefaultIgnores {
    /// Caches that apps or system services need; never listed.
    static let protectedCaches = ["CloudKit", "com.apple.bird", "com.apple.akd", "com.apple.nsurlsessiond", "FamilyCircle",
                                  "com.apple.HomeKit", "com.apple.containermanagerd", "com.apple.ap.adprivacyd", "GeoServices"]

    static func isProtectedCache(_ name: String) -> Bool {
        isOwn(name) || protectedCaches.contains { name == $0 || name.hasPrefix($0 + ".") }
    }

    /// Vibe Cleaner's own files.
    static func isOwn(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("vibecleaner") || n == Bundle.main.bundleIdentifier?.lowercased()
    }
}
