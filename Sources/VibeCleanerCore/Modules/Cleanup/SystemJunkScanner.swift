import Foundation

/// Broken items, document versions, iOS backups and deleted users.
enum SystemJunkScanner {

    // MARK: Broken preferences

    static func isBrokenPreference(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), url.pathExtension.lowercased() == "plist", !url.path.contains(".lockfile"),
              let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isUserImmutableKey, .isRegularFileKey]),
              v.isRegularFile == true, (v.fileSize ?? 0) > 0, v.isUserImmutable != true,
              let data = try? Data(contentsOf: url) else { return false }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
    }

    static func brokenPreferences(_ s: JunkScope) -> ResultGroup {
        let items = Junk.children(s.lib("Preferences")).filter(isBrokenPreference).compactMap {
            // Not selected: an app may be writing it right now (an unreadable plist is not always a dead one).
            s.item($0, detail: "Fichier de préférences illisible", mode: .trash, auto: false)
        }
        return ResultGroup(id: "cleanup.system.brokenPrefs", title: "Préférences cassées",
                           subtitle: "Fichiers .plist corrompus que les apps ne peuvent plus lire", symbol: "gearshape.2", items: items)
    }

    // MARK: Broken launch agents and login items

    /// Absolute program path of a launchd plist. Nil when none is declared (an empty or Label-only plist, as left by
    /// Google Keystone or AWS SessionManagerPlugin, is not broken) or when it cannot be judged (PATH lookup, BundleProgram).
    static func launchProgram(_ dict: [String: Any], home: URL) -> String? {
        guard var p = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first, !p.isEmpty else { return nil }
        if p.hasPrefix("~") { p = home.path + p.dropFirst() }
        if !p.hasPrefix("/") {
            guard let wd = dict["WorkingDirectory"] as? String else { return nil }
            p = (wd as NSString).appendingPathComponent(p)
        }
        return (p as NSString).standardizingPath
    }

    /// True only when `program` is provably absent: its nearest existing ancestor folder can be searched.
    /// A program under a folder we may not read (root-only) is never reported.
    static func isMissing(_ program: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
        // Under a TCC folder, a refused stat looks like a missing file (and may prompt): never call it broken.
        if FullDiskAccess.isUnder(program, FullDiskAccess.promptingFolders(home: home)) { return false }
        var st = stat()
        if lstat(program, &st) == 0 { return false }
        guard errno == ENOENT else { return false }
        let fm = Junk.fm
        var dir = (program as NSString).deletingLastPathComponent
        while !dir.isEmpty, dir != "/", !fm.fileExists(atPath: dir) { dir = (dir as NSString).deletingLastPathComponent }
        return access(dir.isEmpty ? "/" : dir, R_OK | X_OK) == 0
    }

    /// User agents always; /Library agents and daemons with the system scope (removed in the admin batch,
    /// bootout then Trash, the same command as Performance).
    static func brokenLaunchAgents(_ s: JunkScope) -> ResultGroup {
        var roots: [(URL, LaunchItem.Scope)] = [(s.lib("LaunchAgents"), .userAgent)]
        if s.system { roots += PerformanceModule.launchRoots.map { (URL(fileURLWithPath: $0.0), $0.1) } }
        var items: [ResultItem] = []
        for (dir, scope) in roots {
            for url in Junk.children(dir) where url.pathExtension == "plist" {
                guard let dict = Junk.plist(url), let program = launchProgram(dict, home: s.home), isMissing(program) else { continue }
                let label = dict["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                if label.hasPrefix("com.apple.") { continue }
                // A program on an unmounted volume may come back.
                let external = program.hasPrefix("/Volumes/")
                // Admin items (/Library agents and daemons) are never selected by default.
                guard var item = s.item(url, name: label, detail: "Programme introuvable : \(program)", mode: .trash,
                                        auto: !external && !scope.needsAdmin) else { continue }
                if scope.needsAdmin {
                    item.action = PerformanceModule.removeCommand(plist: url, domain: scope == .daemon ? "system" : "gui/\(getuid())")
                }
                items.append(item)
            }
        }
        return ResultGroup(id: "cleanup.system.brokenLaunchAgents", title: "Éléments de démarrage cassés",
                           subtitle: "Agents de lancement et éléments de connexion dont le programme n'existe plus", symbol: "bolt.slash",
                           items: items + brokenLoginItems(s.system ? LoginItems.list() : [], s))
    }

    static let loginItemKey = PerformanceModule.Key.removeLoginItem

    /// Login items whose target no longer exists. An entry that does not resolve at all
    /// (alias on an unmounted volume, or truly gone) is listed but not selected.
    static func brokenLoginItems(_ entries: [LoginItems.Entry], _ s: JunkScope) -> [ResultItem] {
        entries.compactMap { e in
            if let url = e.url {
                guard !Junk.exists(url), !s.context.isExcluded(url) else { return nil }
                return ResultItem(id: "cleanup.loginitem.\(url.path)", name: e.name, detail: "Élément de connexion introuvable : \(url.path)",
                                  url: url, symbol: "person.crop.circle.badge.exclamationmark",
                                  action: .custom(loginItemKey), autoSelect: !url.path.hasPrefix("/Volumes/"))
            }
            return ResultItem(id: "cleanup.loginitem.\(e.name)", name: e.name, detail: "Élément de connexion dont l'emplacement est inconnu",
                              symbol: "person.crop.circle.badge.exclamationmark", action: .custom(loginItemKey), autoSelect: false)
        }
    }

    // MARK: Document versions

    static let versionGap: TimeInterval = 4 * 3600

    /// Dates sorted newest first. The newest and oldest are kept; an intermediate version is selected
    /// when less than 4 h separate it from its newer neighbour.
    static func versionSelection(_ dates: [Date]) -> [Bool] {
        dates.indices.map { i in
            i > 0 && i < dates.count - 1 && dates[i - 1].timeIntervalSince(dates[i]) < versionGap
        }
    }

    static let documentTypes: [(type: String, app: String)] = [
        ("com.bohemiancoding.sketch.drawing.single", "Sketch"), ("com.apple.iwork.pages.sffpages", "Pages"),
        ("com.apple.iwork.keynote.sffkey", "Keynote"), ("com.apple.iwork.numbers.numbers", "Numbers"),
    ]

    /// NSFileVersion.remove() cannot be undone: listed (intermediate versions flagged), never selected by default.
    static func versionItem(_ doc: URL, date: Date, size: Int64, intermediate: Bool) -> ResultItem {
        var item = ResultItem(id: "\(doc.path)#\(date.timeIntervalSince1970)", name: Junk.format(date),
                              detail: intermediate ? "Version intermédiaire — \(doc.path)" : doc.path, url: doc,
                              size: size, date: date, symbol: "doc.badge.clock", action: .custom(CleanupModule.versionKey), autoSelect: false)
        item.customIsIrreversible = true
        return item
    }

    static func documentVersions(_ s: JunkScope) -> ResultGroup {
        var g = ResultGroup(id: "cleanup.system.documentVersions", title: "Versions de documents",
                            subtitle: "Anciennes versions enregistrées automatiquement (Pages, Numbers, Keynote, Sketch)", symbol: "clock.badge.checkmark")
        for (type, app) in documentTypes {
            if Task.isCancelled { break }
            let found = Shell.run("/usr/bin/mdfind", ["-onlyin", s.home.path, "kMDItemContentType == '\(type)'"]).stdout
            var appGroup = ResultGroup(id: "\(g.id).\(app)", title: app)
            for path in found.split(whereSeparator: \.isNewline).map(String.init) {
                let doc = URL(fileURLWithPath: path)
                guard !s.context.isExcluded(doc) else { continue }
                let versions = (NSFileVersion.otherVersionsOfItem(at: doc) ?? [])
                    .compactMap { v in v.modificationDate.map { (v, $0) } }
                    .sorted { $0.1 > $1.1 }
                guard !versions.isEmpty else { continue }
                let picks = versionSelection(versions.map(\.1))
                let items = versions.enumerated().map { i, pair in
                    versionItem(doc, date: pair.1, size: FileSizer.size(of: pair.0.url), intermediate: picks[i])
                }
                appGroup.groups.append(ResultGroup(id: path, title: doc.lastPathComponent, items: items))
            }
            g.groups.append(appGroup)
        }
        return g
    }

    // MARK: iOS backups

    struct Backup { let url: URL; let device: String?; let deviceID: String; let product: String?; let date: Date? }

    static func readBackup(_ url: URL) -> Backup {
        let info = Junk.plist(url.appendingPathComponent("Info.plist")) ?? [:]
        let status = Junk.plist(url.appendingPathComponent("Status.plist")) ?? [:]
        let device = info["Device Name"] as? String
        let id = info["Target Identifier"] as? String ?? info["Unique Identifier"] as? String ?? device ?? url.lastPathComponent
        return Backup(url: url, device: device, deviceID: id, product: info["Product Type"] as? String,
                      date: status["Date"] as? Date ?? info["Last Backup Date"] as? Date)
    }

    static func iosBackups(_ s: JunkScope) -> ResultGroup {
        var g = ResultGroup(id: "cleanup.system.iosBackups", title: "Sauvegardes iOS",
                            subtitle: "Anciennes sauvegardes d'iPhone et d'iPad ; la plus récente de chaque appareil est gardée", symbol: "iphone")
        let root = s.lib("Application Support/MobileSync/Backup").resolvingSymlinksInPath()
        let backups = Junk.children(root).filter(Junk.isDirectory).map(readBackup)
        // A backup without Info.plist may be one in progress: not selected while written to in the last hour.
        let broken = backups.filter { $0.device == nil }.compactMap {
            s.item($0.url, name: $0.url.lastPathComponent, detail: "Sauvegarde incomplète ou cassée", mode: .trash,
                   auto: !s.recentlyModified($0.url, window: 3600))
        }
        if !broken.isEmpty { g.groups.append(ResultGroup(id: "\(g.id).broken", title: "Sauvegardes cassées", items: broken)) }
        let byDevice = Dictionary(grouping: backups.filter { $0.device != nil }, by: \.deviceID)
        for (id, list) in byDevice.sorted(by: { $0.key < $1.key }) {
            let sorted = list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let items = sorted.enumerated().compactMap { i, b in
                // `date` stays the folder's modification date: the executor compares it before removing.
                s.item(b.url, name: Junk.format(b.date), detail: i == 0 ? "Sauvegarde la plus récente" : b.product, mode: .trash, auto: i > 0)
            }
            g.groups.append(ResultGroup(id: "\(g.id).\(id)", title: sorted[0].device ?? id, subtitle: sorted[0].product, symbol: "iphone", items: items))
        }
        return g
    }

    // MARK: Deleted users

    static func deletedUsers(_ s: JunkScope) -> ResultGroup? {
        guard s.system else { return nil }
        let items = Junk.children(URL(fileURLWithPath: "/Users/Deleted Users")).filter { $0.pathExtension == "dmg" }.compactMap {
            s.item($0, detail: "Image disque d'un compte supprimé", mode: .trash, auto: false)
        }
        return ResultGroup(id: "cleanup.system.deletedUsers", title: "Utilisateurs supprimés",
                           subtitle: "Pas forcément inutile : à vérifier avant suppression", symbol: "person.crop.circle.badge.minus", items: items)
    }
}
