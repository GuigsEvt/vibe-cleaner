import AppKit
import Foundation

/// Apps the user dragged to the Trash, with the files they left in the Library.
public enum TrashedApps {
    public struct Entry: Sendable, Identifiable {
        public var id: String { app.url.path }
        /// The bundle, still in the Trash.
        public let app: InstalledApp
        /// Associated files outside the Trash (preferences, caches, containers, launch agents…).
        public let leftovers: [URL]
        public let size: Int64
    }

    /// Read-only. `installed` defaults to a fresh inventory; pass the one you already have to avoid rebuilding it.
    /// Apps whose bundle id is still installed elsewhere, and apps without leftovers, are not returned.
    public static func find(home: URL = URL(fileURLWithPath: NSHomeDirectory()), installed: [InstalledApp]? = nil,
                            fullDiskAccess: Bool = false) -> [Entry] {
        let apps = installed ?? ApplicationsModule().installedApps(home: home)
        return find(home: home, installed: apps, finder: AppFootprint(home: home, installed: apps, fullDiskAccess: fullDiskAccess))
    }

    /// `locate`: every copy of an app LaunchServices knows (`urlsForApplications`), injected by tests. A copy outside a
    /// Trash (another volume, a folder the inventory does not scan) still uses the files. Name matching never takes the
    /// files of an installed app with the same name (see `AppFootprint.hasNamesake`).
    static func find(home: URL, installed: [InstalledApp], finder: AppFootprint,
                     locate: (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }) -> [Entry] {
        let ids = Set(installed.compactMap { $0.bundleID?.lowercased() })
        return bundles(home: home).compactMap { app in
            guard let id = app.bundleID?.lowercased(), !ids.contains(id), !app.isProtected,
                  !locate(app.bundleID ?? id).contains(where: { !isInTrash($0) }) else { return nil }
            let files = finder.footprint(of: app).filter { !$0.path.hasPrefix(app.url.path + "/") }
            guard !files.isEmpty else { return nil }
            return Entry(app: app, leftovers: files, size: files.reduce(0) { $0 + FileSizer.size(of: $1) })
        }
    }

    /// ~/.Trash or a volume's .Trashes folder.
    static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// `.app` bundles at the top of ~/.Trash and one folder below.
    static func bundles(home: URL) -> [InstalledApp] {
        AppInventory.appURLs(in: [home.appendingPathComponent(".Trash")]).compactMap { AppInventory.load($0, isSystem: false) }
    }
}
