import Foundation

/// Startup disk split into Apps, Desktop, Documents, Downloads and Other.
/// Walks the folders recursively: compute it in the background, rarely, and only with Full Disk Access,
/// since listing Desktop / Documents / Downloads without it opens a macOS permission prompt.
public struct StorageBreakdown: Sendable, Hashable {
    public struct Part: Sendable, Hashable, Identifiable {
        public let title: String
        public let bytes: Int64
        public var id: String { title }
    }

    public let parts: [Part]
    public let date: Date

    public init(parts: [Part], date: Date = Date()) {
        self.parts = parts
        self.date = date
    }

    /// `used` is the volume's used space; "Autres" is what the named folders don't account for.
    public static func compute(home: URL, applications: [URL] = [URL(fileURLWithPath: "/Applications")], used: Int64,
                               size: (URL) -> Int64 = FileSizer.size(of:)) -> StorageBreakdown {
        let apps = (applications + [home.appendingPathComponent("Applications")]).reduce(Int64(0)) { $0 + size($1) }
        var parts = [Part(title: "Apps", bytes: apps)]
        for (title, folder) in [("Bureau", "Desktop"), ("Documents", "Documents"), ("Téléchargements", "Downloads")] {
            parts.append(Part(title: title, bytes: size(home.appendingPathComponent(folder))))
        }
        let known = parts.reduce(Int64(0)) { $0 + $1.bytes }
        parts.append(Part(title: "Autres", bytes: max(0, used - known)))
        return StorageBreakdown(parts: parts)
    }
}

/// Apps left in the Trash while their support files stay in ~/Library.
/// Minimal detection for the alert; the Applications module removes the leftovers.
public enum TrashWatch {
    public struct App: Sendable, Hashable, Identifiable {
        public let url: URL
        public let name: String
        public let bundleID: String
        public let leftovers: [URL]
        public var id: String { url.path }
    }

    /// Top-level `.app` bundles of `~/.Trash` whose bundle id still has files in ~/Library
    /// and that are not installed again in one of `installedDirs`.
    public static func find(home: URL, installedDirs: [URL] = [URL(fileURLWithPath: "/Applications")]) -> [App] {
        let fm = FileManager.default
        let trash = home.appendingPathComponent(".Trash")
        guard let entries = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return [] }
        let lib = home.appendingPathComponent("Library")
        return entries.filter { $0.pathExtension == "app" }.compactMap { app in
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String, !id.hasPrefix("com.apple.") else { return nil }
            let reinstalled = (installedDirs + [home.appendingPathComponent("Applications")])
                .contains { fm.fileExists(atPath: $0.appendingPathComponent(app.lastPathComponent).path) }
            guard !reinstalled else { return nil }
            let candidates = ["Preferences/\(id).plist", "Containers/\(id)", "Caches/\(id)", "Application Support/\(id)",
                              "HTTPStorages/\(id)", "Saved Application State/\(id).savedState"].map { lib.appendingPathComponent($0) }
            let leftovers = candidates.filter { fm.fileExists(atPath: $0.path) }
            guard !leftovers.isEmpty else { return nil }
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
            return App(url: app, name: name, bundleID: id, leftovers: leftovers)
        }
    }
}
