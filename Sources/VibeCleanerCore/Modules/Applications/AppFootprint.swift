import Foundation

/// Name-matching rules shared by the footprint finder and the leftovers detector.
enum AppMatch {
    static let genericNames: Set<String> = ["helper", "updater", "utilities", "settings", "data", "cache", "caches", "support",
                                            "plugins", "google", "microsoft", "adobe", "apple", "launcher", "agent", "service",
                                            "tools", "preferences", "logs", "app", "application", "code", "notes", "music"]

    /// `name` is the id itself or starts with `id + "."` (case-insensitive). Never a partial prefix without a dot.
    static func matchesBundleID(_ name: String, _ id: String) -> Bool {
        let n = name.lowercased(), i = id.lowercased()
        return !i.isEmpty && (n == i || n.hasPrefix(i + "."))
    }

    /// An id specific enough to claim files by prefix: at least three non-empty components ("com.vendor.app").
    /// A bundle declaring "com" or "com.vendor" would otherwise claim every file of that vendor, or of everyone.
    static func isSpecificID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && !parts.contains(where: \.isEmpty)
    }

    /// Same vendor prefix ("com.docker.vmnetd" and "com.docker.docker"): what an app may claim beyond its own id.
    static func sameVendor(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(separator: "."), y = b.lowercased().split(separator: ".")
        return x.count >= 2 && y.count >= 2 && x.prefix(2) == y.prefix(2)
    }

    static func words(_ s: String) -> [Substring] {
        s.lowercased().split(whereSeparator: { " ._-\t\n".contains($0) })
    }

    /// All words of the app name appear among the words of `fileName`. Rejects "<name> <digits>…"
    /// (data of another major version installed side by side) and names too short or generic to be safe.
    static func matchesAppName(_ fileName: String, _ appName: String) -> Bool {
        let app = appName.lowercased()
        guard app.count >= 4, !genericNames.contains(app) else { return false }
        let file = fileName.lowercased()
        if isVersionedName(file, app) { return false }
        let fileWords = Set(words(file))
        let appWords = words(app)
        return !appWords.isEmpty && appWords.allSatisfy(fileWords.contains)
    }

    static func isVersionedName(_ file: String, _ app: String) -> Bool {
        guard file.hasPrefix(app) else { return false }
        return file.dropFirst(app.count).drop(while: { $0 == " " || $0 == "\t" }).first?.isNumber == true
    }

    /// Reverse-DNS id from a file name ("com.foo.Bar", "com.foo.Bar.plist" with `stripping: ["plist"]`), else nil.
    static func reverseDNS(_ name: String, stripping exts: Set<String> = []) -> String? {
        var base = name
        let ext = (name as NSString).pathExtension
        if exts.contains(ext.lowercased()) { base = (name as NSString).deletingPathExtension }
        let parts = base.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let tld = parts.first, (2...6).contains(tld.count), tld.allSatisfy(\.isLetter) else { return nil }
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed) }) else { return nil }
        return base
    }
}

/// Files that belong to an installed app. Directory listings and launchd plists are read once at init,
/// then `footprint(of:)` is pure in-memory matching. Symlinks are never followed.
public struct AppFootprint: Sendable {
    struct Root: Sendable { let dir: URL; let byName: Bool; let entries: [URL] }
    struct LaunchJob: Sendable { let url: URL; let associated: [String]; let program: String? }

    let home: URL
    let roots: [Root]
    let groupContainers: [URL]
    let launchJobs: [LaunchJob]
    let helperTools: [URL]
    let receipts: [URL]
    let crashReports: [URL]
    let installedIDs: [String]
    let installedNames: [String]
    /// Standardized bundle paths, parallel to `installedNames`.
    let installedPaths: [String]
    /// Embedded bundle id (lower-cased) → standardized paths of the installed apps shipping it.
    let embeddedOwners: [String: Set<String>]
    /// App groups declared by several installed apps (Office suite...): never attributed to a single app.
    let sharedGroups: Set<String>
    let plugins: [Plugins.Plugin]
    let downloads: [URL]
    /// Symbolic links of command-line folders with their resolved destination.
    let binLinks: [(url: URL, target: String)]
    /// Standardized paths of the apps kept in the Dock.
    let dockApps: Set<String>
    let loginItems: [LoginItems.Entry]

    /// `fullDiskAccess`: Downloads is only read with it (otherwise macOS shows a prompt).
    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), installed: [InstalledApp], fullDiskAccess: Bool = false) {
        self.init(home: home, localLibrary: URL(fileURLWithPath: "/Library"),
                  receiptsDir: URL(fileURLWithPath: "/var/db/receipts"),
                  darwinDirs: [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap(Junk.confstrPath),
                  binDirs: Self.defaultBinDirs, loginItems: LoginItems.list(), installed: installed, downloads: fullDiskAccess)
    }

    static let defaultBinDirs = ["/usr/local/bin", "/opt/homebrew/bin"].map { URL(fileURLWithPath: $0) }

    /// `darwinDirs`: the per-user cache and temporary folders under /var/folders, holding one folder per bundle id.
    init(home: URL, localLibrary: URL, receiptsDir: URL, darwinDirs: [URL] = [], binDirs: [URL] = [],
         loginItems: [LoginItems.Entry] = [], installed: [InstalledApp], downloads readsDownloads: Bool = false) {
        self.home = home
        let user = home.appendingPathComponent("Library")
        let userRoots: [(String, Bool)] = [("Application Support", true), ("Caches", true), ("Logs", true), ("Preferences", true),
                                           ("Preferences/ByHost", false), ("HTTPStorages", false), ("WebKit", false),
                                           ("Saved Application State", false), ("Containers", false), ("Cookies", false),
                                           ("Application Scripts", false)]
        let localRoots: [(String, Bool)] = [("Application Support", true), ("Caches", true), ("Logs", true), ("Preferences", true)]
        roots = userRoots.map { Self.root(user.appendingPathComponent($0.0), $0.1) }
            + localRoots.map { Self.root(localLibrary.appendingPathComponent($0.0), $0.1) }
            + darwinDirs.map { Self.root($0, false) }
        crashReports = [user, localLibrary].flatMap { AppInventory.children(of: $0.appendingPathComponent("Logs/DiagnosticReports")) }
        groupContainers = AppInventory.children(of: user.appendingPathComponent("Group Containers"))
        let launchDirs = [user.appendingPathComponent("LaunchAgents"), localLibrary.appendingPathComponent("LaunchAgents"),
                          localLibrary.appendingPathComponent("LaunchDaemons")]
        launchJobs = launchDirs.flatMap(AppInventory.children(of:)).filter { $0.pathExtension == "plist" }.map(Self.job)
        helperTools = AppInventory.children(of: localLibrary.appendingPathComponent("PrivilegedHelperTools"))
        receipts = AppInventory.children(of: receiptsDir).filter { ["plist", "bom"].contains($0.pathExtension) }
        installedIDs = installed.compactMap { $0.bundleID?.lowercased() }
        installedNames = installed.map(\.name)
        installedPaths = installed.map { $0.url.standardizedFileURL.path }
        var owners: [String: Set<String>] = [:]
        for a in installed { for id in a.embeddedBundleIDs { owners[id.lowercased(), default: []].insert(a.url.standardizedFileURL.path) } }
        embeddedOwners = owners
        var groupCount: [String: Int] = [:]
        for g in installed.flatMap({ Set($0.appGroups.map { $0.lowercased() }) }) { groupCount[g, default: 0] += 1 }
        sharedGroups = Set(groupCount.filter { $0.value > 1 }.keys)
        plugins = Plugins.find(libraries: [user, localLibrary])
        downloads = readsDownloads ? AppInventory.children(of: home.appendingPathComponent("Downloads")) : []
        binLinks = binDirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap { url in
                guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
                return (url, URL(fileURLWithPath: dest, relativeTo: dir).standardizedFileURL.path)
            }
        }
        let dock = AppInventory.readPlist(user.appendingPathComponent("Preferences/com.apple.dock.plist"))
        dockApps = Set(((dock?["persistent-apps"] as? [[String: Any]]) ?? []).compactMap { tile in
            let file = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
            return (file?["_CFURLString"] as? String).flatMap { URL(string: $0)?.standardizedFileURL.path }
        })
        self.loginItems = loginItems
    }

    static func root(_ dir: URL, _ byName: Bool) -> Root { Root(dir: dir, byName: byName, entries: AppInventory.children(of: dir)) }

    static func job(_ url: URL) -> LaunchJob {
        let d = AppInventory.readPlist(url) ?? [:]
        let assoc = d["AssociatedBundleIdentifiers"]
        let ids = (assoc as? [String]) ?? (assoc as? String).map { [$0] } ?? []
        let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first ?? (d["BundleProgram"] as? String)
        return LaunchJob(url: url, associated: ids, program: program)
    }

    /// Associated files of `app`, excluding the bundle itself. Receipts are `/var/db/receipts/<pkgid>.{plist,bom}`.
    static let installerArchives = ClutterModule.installerExtensions.union(["zip"])

    public func footprint(of app: InstalledApp) -> [URL] {
        guard let bundleID = app.bundleID else { return [] }
        let path = app.url.standardizedFileURL.path
        // An embedded id shipped by another installed app too (shared updater, framework helper) belongs to neither.
        // A bundle may only claim ids of its own vendor, specific enough not to cover other apps: an adware declaring
        // "com" or another vendor's helper id must not drag that vendor's daemons into its uninstall.
        let ids = ([bundleID] + app.embeddedBundleIDs.filter { id in
            AppMatch.sameVendor(id, bundleID)
                && !installedIDs.contains(id.lowercased()) && embeddedOwners[id.lowercased(), default: []].subtracting([path]).isEmpty
        }).filter(AppMatch.isSpecificID)
        let privileged = app.privilegedExecutables.filter { AppMatch.sameVendor($0, bundleID) && AppMatch.isSpecificID($0) }
        let isApple = bundleID.lowercased().hasPrefix("com.apple.")
        let useName = app.name.lowercased() != bundleID.lowercased() && !hasNamesake(app)
        var out = Set<URL>()

        func byID(_ name: String) -> Bool { ids.contains { owns(name, $0) } }

        for root in roots {
            for entry in root.entries {
                let name = entry.lastPathComponent
                if !isApple && name.lowercased().hasPrefix("com.apple.") { continue }
                if byID(name) { out.insert(entry); continue }
                // Name matching never steals another installed app's id-named files ("Winamax Poker" vs com.winamax.poker).
                // The cheap name test first: the scan over every installed id only runs for the rare names that match.
                if root.byName && useName && ownsByName(name, app.name)
                    && !installedIDs.contains(where: { AppMatch.matchesBundleID(name, $0) }) { out.insert(entry) }
            }
        }
        for entry in groupContainers {
            let name = entry.lastPathComponent
            if !isApple && name.lowercased().contains("com.apple.") { continue }
            if sharedGroups.contains(name.lowercased()) { continue }
            if app.appGroups.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { out.insert(entry); continue }
            if let team = app.teamID, name.hasPrefix(team + "."), byID(String(name.dropFirst(team.count + 1))) { out.insert(entry) }
        }
        let bundlePrefix = app.url.standardizedFileURL.path + "/"
        for job in launchJobs {
            let name = job.url.deletingPathExtension().lastPathComponent
            if byID(name) || privileged.contains(name)
                || job.associated.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
                || job.program.map({ URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(bundlePrefix) }) == true {
                out.insert(job.url)
            }
        }
        for tool in helperTools where privileged.contains(tool.lastPathComponent) || byID(tool.lastPathComponent) {
            out.insert(tool)
        }
        for r in receipts where AppMatch.isSpecificID(bundleID) && owns(r.deletingPathExtension().lastPathComponent, bundleID) { out.insert(r) }
        for p in plugins where p.bundleID.map(byID) == true
            || (useName && ownsByName(p.url.deletingPathExtension().lastPathComponent, app.name)) { out.insert(p.url) }
        for d in downloads where Self.installerArchives.contains(d.pathExtension.lowercased())
            && isInstaller(d.deletingPathExtension().lastPathComponent, of: app.name) { out.insert(d) }
        for link in binLinks where link.target.hasPrefix(bundlePrefix) { out.insert(link.url) }
        let processNames = Set([app.name, app.url.deletingPathExtension().lastPathComponent])
        for report in crashReports where processNames.contains(where: { Self.isCrashReport(report.lastPathComponent, of: $0) }) {
            out.insert(report)
        }
        return out.sorted { $0.path < $1.path }
    }

    func isInDock(_ app: InstalledApp) -> Bool { dockApps.contains(app.url.standardizedFileURL.path) }

    /// Login items ("Ouvrir à la connexion") pointing at the app or inside its bundle.
    func loginItems(of app: InstalledApp) -> [LoginItems.Entry] {
        let path = app.url.standardizedFileURL.path
        return loginItems.filter { e in e.url.map { $0.standardizedFileURL.path == path || $0.standardizedFileURL.path.hasPrefix(path + "/") } == true }
    }

    /// "Firefox 131.0.dmg", "Install Bar App (arm64).pkg": every word of the app name, versions allowed,
    /// unless an installed app with more words also matches.
    func isInstaller(_ stem: String, of appName: String) -> Bool { Self.isInstaller(stem, of: appName, installedNames: installedNames) }

    static func isInstaller(_ stem: String, of appName: String, installedNames: [String]) -> Bool {
        let app = appName.lowercased()
        guard app.count >= 4, !AppMatch.genericNames.contains(app) else { return false }
        let words = Set(AppMatch.words(stem))
        func matches(_ name: String) -> Bool { let w = AppMatch.words(name); return !w.isEmpty && w.allSatisfy(words.contains) }
        guard matches(appName) else { return false }
        let n = AppMatch.words(appName).count
        return !installedNames.contains { AppMatch.words($0).count > n && matches($0) }
    }

    /// "<process>-2026-10-20-101112.ips" or "<process>_2026-…" (macOS names reports after the process).
    static func isCrashReport(_ file: String, of process: String) -> Bool {
        guard process.count >= 3, ["ips", "crash", "hang", "spin", "diag"].contains((file as NSString).pathExtension),
              file.hasPrefix(process) else { return false }
        let rest = file.dropFirst(process.count)
        return (rest.first == "-" || rest.first == "_") && rest.dropFirst().first?.isNumber == true
    }

    /// Bundle-id match, unless a longer installed id claims the same file (com.foo.app vs com.foo.app.pro).
    func owns(_ name: String, _ id: String) -> Bool {
        guard AppMatch.matchesBundleID(name, id) else { return false }
        let n = id.count
        return !installedIDs.contains { $0.count > n && AppMatch.matchesBundleID(name, $0) }
    }

    /// Another installed app has the same words in its name ("CleanShot X" from the App Store and from Setapp):
    /// a file named after it could belong to either, so neither claims it by name.
    func hasNamesake(_ app: InstalledApp) -> Bool {
        let words = Set(AppMatch.words(app.name)), path = app.url.standardizedFileURL.path
        return zip(installedNames, installedPaths).contains { $0.1 != path && Set(AppMatch.words($0.0)) == words }
    }

    /// Name match, unless an installed app with more words also matches ("Google Chrome" vs "Google Chrome Canary").
    func ownsByName(_ fileName: String, _ appName: String) -> Bool {
        guard AppMatch.matchesAppName(fileName, appName) else { return false }
        let n = AppMatch.words(appName).count
        return !installedNames.contains { AppMatch.words($0).count > n && AppMatch.matchesAppName(fileName, $0) }
    }
}
