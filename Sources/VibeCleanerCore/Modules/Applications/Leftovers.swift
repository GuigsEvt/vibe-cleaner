import AppKit
import Foundation

/// Files named after a bundle id that no installed app, helper, group or executable claims.
enum Leftovers {
    struct Hit: Sendable, Equatable {
        let ownerID: String
        let url: URL
        /// Clearly orphaned: preference/container/cache with an exact id, untouched for a month.
        let clear: Bool
    }

    static let systemPrefixes = ["com.apple.", "group.com.apple.", "systemgroup.com.apple.", "org.cups.", "com.openssh.",
                                 "org.openssh.", "org.swift.", "org.llvm.", "is.workflow.", ApplicationsModule.selfBundleID]
    static let defaultExecutableDirs = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/usr/libexec"]
        .map { URL(fileURLWithPath: $0) }

    struct Root {
        let dir: URL
        let exts: Set<String>
        /// Regenerable or state data: preselected when stale.
        let clear: Bool
    }

    static func roots(home: URL, localLibrary: URL?) -> [Root] {
        let lib = home.appendingPathComponent("Library")
        // Containers hold sandboxed apps' documents and databases: listed for review, never preselected.
        let user: [(String, Set<String>, Bool)] = [
            ("Preferences", ["plist"], true), ("Containers", [], false), ("Caches", [], true), ("Application Support", [], false),
            ("Group Containers", [], false), ("Saved Application State", ["savedstate"], true), ("Cookies", ["binarycookies"], true),
            ("HTTPStorages", [], true), ("WebKit", [], true), ("Logs", [], true), ("LaunchAgents", ["plist"], false),
        ]
        // Root-owned: listed for review, never preselected.
        let local: [(String, Set<String>)] = [("Application Support", []), ("Caches", []), ("Preferences", ["plist"]), ("Logs", []),
                                              ("LaunchAgents", ["plist"]), ("LaunchDaemons", ["plist"])]
        return user.map { Root(dir: lib.appendingPathComponent($0.0), exts: $0.1, clear: $0.2) }
            + (localLibrary.map { l in local.map { Root(dir: l.appendingPathComponent($0.0), exts: $0.1, clear: false) } } ?? [])
    }

    /// `localLibrary` nil skips /Library (tests). `componentIDs`: ids of installed plug-ins, system extensions and
    /// package receipts (`componentIDs(libraries:systemExtensions:receiptsDir:)`), known like those of installed apps.
    static func find(home: URL, localLibrary: URL? = nil, installed: [InstalledApp], executableDirs: [URL] = defaultExecutableDirs,
                     isRegistered: (String) -> Bool = Leftovers.isRegistered, componentIDs: [String] = []) -> [Hit] {
        let known = knownIDs(installed).union(componentIDs.map { $0.lowercased() })
        let vendors = Set(known.map(vendor))
        let teams = Set(installed.compactMap { $0.teamID?.lowercased() })
        let monthAgo = Date().addingTimeInterval(-30 * 86_400)
        var cache: [String: Bool] = [:]
        var hits: [Hit] = []
        for root in roots(home: home, localLibrary: localLibrary) {
            let isGroups = root.dir.lastPathComponent == "Group Containers"
            let isLaunchd = root.dir.lastPathComponent.hasPrefix("Launch")
            for entry in AppInventory.children(of: root.dir) {
                if Task.isCancelled { return hits }
                if !root.exts.isEmpty && !root.exts.contains(entry.pathExtension.lowercased()) { continue }
                var name = entry.lastPathComponent
                let full = name.lowercased()
                if isGroups {
                    // "group.com.foo.app", "<TEAMID>.com.foo.app" or "<TEAMID>.groups.com.foo.app"; a team shared with
                    // an installed app keeps its data.
                    if let dot = name.firstIndex(of: "."), isTeamID(name[..<dot]) {
                        if teams.contains(name[..<dot].lowercased()) { continue }
                        name = String(name[name.index(after: dot)...])
                    }
                    for prefix in ["group.", "groups."] where name.lowercased().hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
                }
                guard let id = AppMatch.reverseDNS(name, stripping: root.exts) else { continue }
                let lower = id.lowercased()
                if systemPrefixes.contains(where: { lower.hasPrefix($0) || lower == $0 || full.hasPrefix($0) }) { continue }
                // Apple data under another prefix ("243LU875E5.groups.com.apple.podcasts").
                if lower.contains(".com.apple.") || full.contains(".com.apple.") { continue }
                if known.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") || full == $0 }) { continue }
                // Same vendor as an installed app (com.microsoft.office with Word installed): shared data, keep it.
                if vendors.contains(vendor(lower)) { continue }
                // A launchd job whose program is still on disk belongs to something installed (CLI tool, helper).
                if isLaunchd, programExists(entry) { continue }
                let orphan = cache[lower] ?? (!isRegistered(id) && !hasExecutable(id, in: executableDirs))
                cache[lower] = orphan
                guard orphan else { continue }
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let stale = modified.map { $0 < monthAgo } ?? false
                hits.append(Hit(ownerID: ownerID(id), url: entry, clear: root.clear && stale))
            }
        }
        return hits
    }

    /// Apple team identifiers: 10 upper-case letters and digits.
    static func isTeamID(_ s: Substring) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static func programExists(_ plist: URL) -> Bool {
        let d = AppInventory.readPlist(plist) ?? [:]
        guard let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first else { return false }
        return FileManager.default.fileExists(atPath: program)
    }

    /// Lower-cased ids of everything installed: bundles, embedded helpers, app groups, privileged helpers.
    static func knownIDs(_ apps: [InstalledApp]) -> Set<String> {
        var ids = Set<String>()
        for a in apps {
            if let id = a.bundleID { ids.insert(id.lowercased()) }
            a.embeddedBundleIDs.forEach { ids.insert($0.lowercased()) }
            a.privilegedExecutables.forEach { ids.insert($0.lowercased()) }
            for g in a.appGroups {
                let l = g.lowercased()
                ids.insert(l.hasPrefix("group.") ? String(l.dropFirst(6)) : l)
            }
        }
        return ids
    }

    /// Ids of stand-alone plug-ins and preference panes in `libraries`, of system extensions and of installed
    /// packages (`<receiptsDir>/<pkgid>.plist|.bom`, only listed). Read only.
    static func componentIDs(libraries: [URL], systemExtensions: [Plugins.SystemExtension], receiptsDir: URL?) -> [String] {
        let receipts = receiptsDir.map { AppInventory.children(of: $0).filter { ["plist", "bom"].contains($0.pathExtension) }
            .map { $0.deletingPathExtension().lastPathComponent } } ?? []
        return Array(Set(Plugins.find(libraries: libraries).compactMap(\.bundleID) + systemExtensions.map(\.bundleID) + receipts))
    }

    static func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }

    static func ownerID(_ id: String) -> String { id.split(separator: ".").prefix(3).joined(separator: ".") }

    /// LaunchServices knows an app with this id (or its 3-component root) anywhere on disk.
    static func isRegistered(_ id: String) -> Bool {
        let ws = NSWorkspace.shared
        return ws.urlForApplication(withBundleIdentifier: id) != nil || ws.urlForApplication(withBundleIdentifier: ownerID(id)) != nil
    }

    /// A command-line tool named like the id's last component is still installed (com.docker.docker → docker).
    static func hasExecutable(_ id: String, in dirs: [URL]) -> Bool {
        guard let last = id.split(separator: ".").last?.lowercased(), last.count >= 3 else { return false }
        return dirs.contains { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent(last).path) }
    }
}
