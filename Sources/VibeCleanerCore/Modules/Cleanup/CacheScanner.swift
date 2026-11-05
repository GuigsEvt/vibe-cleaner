import AppKit
import Foundation

/// Caches, temporary files and developer tool caches. Caches are regenerable: permanent removal.
enum CacheScanner {
    /// Folders of ~/Library/Caches shown under "Caches de développement" instead of the user caches.
    static let devCacheNames: Set<String> = ["Homebrew", "pip", "Yarn", "CocoaPods", "org.carthage.CarthageKit", "org.swift.swiftpm", "go-build"]

    // MARK: User caches

    static func userCaches(_ s: JunkScope) -> ResultGroup {
        var buckets: [String: [ResultItem]] = [:]
        func add(_ key: String, _ item: ResultItem?) { if let item { buckets[key, default: []].append(item) } }
        func cacheItem(_ url: URL, owner: String, name: String? = nil, knownOwner: Bool = true, open: Bool? = nil) -> ResultItem? {
            let open = open ?? s.isRunning(owner), recent = !open && s.recentlyModified(url)
            let why = open ? "App ouverte — " : recent ? "Modifié il y a moins de 10 min — " : knownOwner ? nil : "Propriétaire inconnu — "
            return s.item(url, name: name, detail: why.map { $0 + url.deletingLastPathComponent().path },
                          mode: .permanent, auto: !open && !recent && knownOwner)
        }

        for url in Junk.children(s.lib("Caches")) {
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            guard !DefaultIgnores.isProtectedCache(name), !devCacheNames.contains(name) else { continue }
            add(name, cacheItem(url, owner: name))
        }

        if s.system, let darwin = Junk.confstrPath(_CS_DARWIN_USER_CACHE_DIR) {
            // System daemon caches live here too; only third-party entries are offered, selected when an installed app owns them.
            let installed = installedBundleIDs(s)
            for url in darwinCacheEntries(darwin) {
                let name = url.lastPathComponent
                add(name, cacheItem(url, owner: name, knownOwner: isInstalledOwner(name, installed: installed)))
            }
        }

        for container in Junk.children(s.lib("Containers")) {
            if Task.isCancelled { break }
            let id = container.lastPathComponent
            guard !DefaultIgnores.isProtectedCache(id) else { continue }
            let caches = container.appendingPathComponent("Data/Library/Caches")
            guard !Junk.isSymlink(caches) else { continue }
            for url in Junk.children(caches) where !DefaultIgnores.isProtectedCache(url.lastPathComponent) {
                add(id, cacheItem(url, owner: id, name: "\(url.lastPathComponent) (conteneur)"))
            }
        }

        for (id, url) in electronCaches(s) { add(id, cacheItem(url, owner: id, name: "\(url.lastPathComponent) (Electron)")) }

        for entry in hardcoded where !entry.system || s.system {
            let root = entry.system ? URL(fileURLWithPath: "/") : s.lib("")
            for url in Junk.glob(root, entry.pattern) {
                let item = s.item(url, name: "\(entry.label) — \(url.lastPathComponent)", mode: entry.mode, auto: entry.auto && !s.isRunning(entry.owner))
                add(entry.label, item)
            }
        }

        // Photos thumbnails: every entry except the most recently accessed one.
        let photos = Junk.children(s.lib("Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0"))
            .sorted { access($0) > access($1) }
        for url in photos.dropFirst() { add("Photos", cacheItem(url, owner: "com.apple.Photos", name: "Photos — \(url.lastPathComponent)")) }

        let dropboxOpen = s.isRunning("com.getdropbox.dropbox") || s.isRunning("Dropbox")
        for url in dropboxCaches(s) { add("Dropbox", cacheItem(url, owner: "Dropbox", name: "Dropbox — \(url.lastPathComponent)", open: dropboxOpen)) }

        if s.system, let darwin = Junk.confstrPath(_CS_DARWIN_USER_CACHE_DIR) {
            let roots = ["com.apple.appstore", "com.apple.appstoreagent"].map { darwin.appendingPathComponent($0) }
            for item in appStoreDownloads(roots, s) { add("App Store", item) }
        }

        return group(id: "cleanup.system.userCaches", title: "Caches utilisateur",
                     subtitle: "Fichiers temporaires que les apps recréent au besoin", symbol: "archivebox", buckets: buckets)
    }

    /// Entries of the darwin cache folder worth listing: not Apple daemons, clang module caches, Spotlight (`mds`)
    /// or saved window state (`PersistedState`).
    static func darwinCacheEntries(_ root: URL) -> [URL] {
        Junk.children(root).filter { url in
            let name = url.lastPathComponent
            return !name.hasPrefix("com.apple.") && !name.hasPrefix("org.llvm.clang") && name != "mds"
                && !name.contains("PersistedState") && !DefaultIgnores.isProtectedCache(name)
        }
    }

    /// Lowercased bundle ids of the apps in /Applications and ~/Applications.
    static func installedBundleIDs(_ s: JunkScope) -> Set<String> {
        Set(Junk.applications(s).compactMap { (Junk.plist($0.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String)?.lowercased() })
    }

    /// A darwin cache named after an installed app ("com.example.app" or "com.example.app.helper"), or one Launch Services knows.
    static func isInstalledOwner(_ name: String, installed: Set<String>,
                                 lookUp: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) -> Bool {
        let n = name.lowercased()
        return installed.contains { n == $0 || n.hasPrefix($0 + ".") } || lookUp(name)
    }

    /// `.dropbox.cache` contents of every account listed in `~/.dropbox/info.json` ({"personal": {"path": …}, …}).
    static func dropboxCaches(_ s: JunkScope) -> [URL] {
        guard let data = try? Data(contentsOf: s.h(".dropbox/info.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let paths = Set(json.values.compactMap { ($0 as? [String: Any])?["path"] as? String })
        return paths.sorted().flatMap { Junk.children(URL(fileURLWithPath: $0).appendingPathComponent(".dropbox.cache"), hidden: true) }
    }

    /// Leftover App Store downloads: folders named after a numeric item id in the App Store darwin caches.
    /// No public manifest lists them; this is the folder layout seen on disk.
    /// Never selected: without the manifest, a paused download cannot be told from a leftover (prudent choice).
    static func appStoreDownloads(_ roots: [URL], _ s: JunkScope, now: Date = Date()) -> [ResultItem] {
        return roots.flatMap { Junk.children($0) }.filter { url in
            let name = url.lastPathComponent
            return !name.isEmpty && name.allSatisfy(\.isNumber) && Junk.isDirectory(url)
        }.compactMap { url in
            let recent = now.timeIntervalSince(Junk.modified(url) ?? now) < 86_400
            return s.item(url, name: "App Store — téléchargement \(url.lastPathComponent)",
                          detail: recent ? "Modifié il y a moins de 24 h — \(url.deletingLastPathComponent().path)" : nil,
                          mode: .permanent, auto: false)
        }
    }

    static func access(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
    }

    /// Single items stay flat; an app with several cache sources gets its own subgroup.
    static func group(id: String, title: String, subtitle: String, symbol: String, buckets: [String: [ResultItem]]) -> ResultGroup {
        var g = ResultGroup(id: id, title: title, subtitle: subtitle, symbol: symbol)
        for (key, items) in buckets.sorted(by: { $0.key < $1.key }) {
            if items.count == 1 { g.items += items } else { g.groups.append(ResultGroup(id: "\(id).\(key)", title: key, items: items)) }
        }
        return g
    }

    /// Chromium caches of Electron apps, keyed by bundle id.
    static func electronCaches(_ s: JunkScope) -> [(String, URL)] {
        var out: [(String, URL)] = []
        for app in Junk.applications(s) {
            guard Junk.exists(app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")) else { continue }
            let info = Junk.plist(app.appendingPathComponent("Contents/Info.plist")) ?? [:]
            let id = info["CFBundleIdentifier"] as? String ?? app.deletingPathExtension().lastPathComponent
            let names = [info["CFBundleName"] as? String, app.deletingPathExtension().lastPathComponent].compactMap { $0 }
            let bases = [s.lib("Application Support"), s.lib("Containers/\(id)/Data/Library/Application Support")]
            var seen = Set<String>()
            for base in bases {
                for name in names {
                    for cache in ["Cache", "Code Cache", "GPUCache"] {
                        let url = base.appendingPathComponent(name).appendingPathComponent(cache)
                        if Junk.exists(url), seen.insert(url.resolvingSymlinksInPath().path).inserted { out.append((id, url)) }
                    }
                }
            }
        }
        return out
    }

    /// `.trash` for folders that hold the user's own media or messages (downloaded videos, music, chat files): not regenerable.
    struct Hardcoded { let label: String; let owner: String; let pattern: String; let auto: Bool; var mode: RemovalMode = .permanent; var system = false }

    /// Paths relative to ~/Library (or to / when `system`).
    static let hardcoded: [Hardcoded] = [
        .init(label: "Telegram", owner: "ru.keepcoder.Telegram", pattern: "Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/*/account-*/postbox/media", auto: false, mode: .trash),
        .init(label: "Telegram Desktop", owner: "com.tdesktop.Telegram", pattern: "Application Support/Telegram Desktop/tdata/user_data/*cache", auto: false),
        .init(label: "Telegram Desktop", owner: "org.telegram.desktop", pattern: "Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data/*cache", auto: false),
        .init(label: "WeChat", owner: "com.tencent.xinWeChat", pattern: "Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9/*/Message/MessageTemp", auto: false, mode: .trash),
        .init(label: "Tencent Video", owner: "com.tencent.tenvideo", pattern: "Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video", auto: false, mode: .trash),
        .init(label: "QQ Music", owner: "com.tencent.QQMusicMac", pattern: "Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic", auto: false, mode: .trash),
        .init(label: "Youku", owner: "com.youku.mac", pattern: "Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE", auto: false),
        .init(label: "Adobe Media Cache", owner: "com.adobe.PremierePro", pattern: "Application Support/Adobe/Common/Media Cache Files", auto: false),
        .init(label: "Spotify", owner: "com.spotify.client", pattern: "Application Support/Spotify/PersistentCache/Storage", auto: false, mode: .trash),
        .init(label: "Cache de migration", owner: "", pattern: "Library/SystemMigration/History/Migration-*/QuarantineRoot/private/var/db/dyld", auto: false, system: true),
    ]

    // MARK: System caches

    static func systemCaches(_ s: JunkScope) -> ResultGroup? {
        guard s.system else { return nil }
        // System daemon caches (com.apple.*) are left alone; the rest needs admin rights when root-owned.
        let items = Junk.children(URL(fileURLWithPath: "/Library/Caches")).compactMap { url -> ResultItem? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("com.apple."), !DefaultIgnores.isProtectedCache(name) else { return nil }
            return s.item(url, mode: .permanent, auto: false)
        }
        return ResultGroup(id: "cleanup.system.systemCaches", title: "Caches système",
                           subtitle: "Caches partagés dans /Library/Caches (droits administrateur)", symbol: "internaldrive",
                           items: items)
    }

    // MARK: Temporary files

    static let tempAge: TimeInterval = 7 * 86_400

    static func temporaryFiles(_ s: JunkScope) -> ResultGroup? {
        guard s.system else { return nil }
        let cutoff = Date().addingTimeInterval(-tempAge)
        let uid = Int(getuid())
        var items: [ResultItem] = []
        var roots = [URL(fileURLWithPath: "/private/tmp")]
        if let t = Junk.confstrPath(_CS_DARWIN_USER_TEMP_DIR) { roots.insert(t, at: 0) }
        for root in roots {
            for url in Junk.children(root) {
                let name = url.lastPathComponent
                guard !name.hasPrefix("com.apple."), name != "TemporaryItems", !DefaultIgnores.isOwn(name),
                      ((try? Junk.fm.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber)?.intValue == uid,
                      let newest = newestDate(in: url), newest < cutoff else { continue }
                if var item = s.item(url, detail: "Inchangé depuis plus de 7 jours — \(root.path)", mode: .permanent, auto: false) {
                    item.date = newest
                    items.append(item)
                }
            }
        }
        return ResultGroup(id: "cleanup.system.temp", title: "Fichiers temporaires",
                           subtitle: "Fichiers temporaires à vous, inchangés depuis plus de 7 jours", symbol: "clock.arrow.circlepath", items: items)
    }

    /// Newest modification date of an item and everything under it. Nil (never offered) when the tree holds a socket
    /// (a live server uses it) or has more than `limit` entries (too long to check).
    static func newestDate(in url: URL, limit: Int = 10_000) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileResourceTypeKey]
        func values(_ u: URL) -> (Date?, Bool) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (v?.contentModificationDate, v?.fileResourceType == .socket)
        }
        let (top, socket) = values(url)
        guard var newest = top, !socket else { return nil }
        guard Junk.isDirectory(url), !Junk.isSymlink(url) else { return newest }
        guard let e = Junk.fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return nil }
        var n = 0
        for case let u as URL in e {
            n += 1
            if n > limit { return nil }
            let (date, socket) = values(u)
            if socket { return nil }
            if let date, date > newest { newest = date }
        }
        return newest
    }

    // MARK: Developer caches

    struct DevCache { let label: String; let path: String; var auto = true }

    static let devCaches: [DevCache] = [
        .init(label: "npm", path: ".npm/_cacache"),
        .init(label: "Yarn", path: "Library/Caches/Yarn"),
        .init(label: "Yarn Berry", path: ".yarn/berry/cache"),
        .init(label: "pip", path: "Library/Caches/pip"),
        .init(label: "CocoaPods", path: "Library/Caches/CocoaPods"),
        .init(label: "Carthage", path: "Library/Caches/org.carthage.CarthageKit"),
        .init(label: "Swift Package Manager", path: "Library/Caches/org.swift.swiftpm"),
        .init(label: "Go (build)", path: "Library/Caches/go-build"),
        .init(label: "Bun", path: ".bun/install/cache"),
        .init(label: "Cargo (registre)", path: ".cargo/registry/cache"),
        .init(label: "Gradle", path: ".gradle/caches", auto: false),
    ]

    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func developerCaches(_ s: JunkScope) -> ResultGroup {
        var items = devCaches.compactMap { c in
            s.item(s.h(c.path), name: c.label, mode: .permanent, auto: c.auto)
        }
        let brewCache = s.lib("Caches/Homebrew")
        if let brew = s.system ? brewPaths.first(where: Junk.fm.isExecutableFile(atPath:)) : nil {
            let size = FileSizer.size(of: brewCache)
            if size > 0, !s.context.isExcluded(brewCache) {
                // Not selected: besides the cache, `brew cleanup` removes the old versions of installed formulae.
                items.append(ResultItem(id: "cleanup.dev.brew", name: "Homebrew",
                                        detail: "brew cleanup -s --prune=all : vide le cache et retire aussi les anciennes versions installées",
                                        url: brewCache, size: size,
                                        action: .command(executable: brew, arguments: ["cleanup", "-s", "--prune=all"], admin: false),
                                        autoSelect: false))
            }
        } else if let item = s.item(brewCache, name: "Homebrew", mode: .permanent) {
            items.append(item)
        }
        return ResultGroup(id: "cleanup.system.devCaches", title: "Caches de développement",
                           subtitle: "Paquets téléchargés par npm, pip, Homebrew, Gradle… (retéléchargés au besoin)", symbol: "hammer", items: items)
    }
}
