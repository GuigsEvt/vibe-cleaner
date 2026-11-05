import Foundation

/// Disk images and installer packages anywhere in the home folder, found through Spotlight (read-only `mdfind`).
enum InstallerSearch {
    static let query = "kMDItemContentType == 'com.apple.disk-image-udif' || kMDItemContentTypeTree == 'com.apple.installer-package-archive'"

    static func spotlight(home: URL) -> [URL] {
        let r = Shell.run("/usr/bin/mdfind", ["-onlyin", home.path, query])
        return r.ok ? r.stdout.split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0)) } : []
    }

    /// Downloads are covered by Fouillis; Library and Trash content is never proposed; nothing inside a bundle.
    /// Without Full Disk Access, Desktop and Documents are skipped too: reading them would show a macOS prompt.
    static func filter(_ urls: [URL], home: URL, fullDiskAccess: Bool = false) -> [URL] {
        let h = home.standardizedFileURL.path
        let skipped = (["Downloads", "Library", ".Trash"] + (fullDiskAccess ? [] : ["Desktop", "Documents"])).map { "\(h)/\($0)/" }
        return urls.filter { url in
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(h + "/"), !skipped.contains(where: p.hasPrefix) else { return false }
            let parents = url.deletingLastPathComponent().pathComponents
            guard !parents.contains(where: { ["app", "pkg", "bundle", "framework"].contains(($0 as NSString).pathExtension.lowercased()) })
            else { return false }
            return FileManager.default.fileExists(atPath: p)
        }
    }
}

/// Updates macOS last found, from the Software Update preferences (world-readable). Nothing is installed here:
/// the user is sent to System Settings.
public enum SystemUpdates {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    static let plist = URL(fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist")

    struct Update: Sendable, Equatable {
        let id: String
        let name: String
    }

    static func pending(plist: URL = plist) -> [Update] {
        let list = AppInventory.readPlist(plist)?["RecommendedUpdates"] as? [[String: Any]] ?? []
        return list.compactMap { u in
            guard let id = (u["Identifier"] as? String) ?? (u["Product Key"] as? String) else { return nil }
            return Update(id: id, name: (u["Display Name"] as? String) ?? id)
        }
    }
}
