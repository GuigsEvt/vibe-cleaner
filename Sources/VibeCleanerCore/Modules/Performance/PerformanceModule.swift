import Foundation

/// Maintenance tasks, login items and third-party launchd jobs.
///
/// Launchd removal: user agents use `.custom` (bootout then Trash, no password); `/Library` jobs use one
/// admin `.command` running a fixed `/bin/sh` script with its values as positional arguments, so bootout and
/// the move into `ActionExecutor.rootTrash` happen in the single batched admin prompt.
public struct PerformanceModule: ScanModule {
    public let id = "performance"
    public let title = "Performance"
    public let subtitle = "Lance des tâches de maintenance et passe en revue ce qui démarre avec votre Mac."
    public let symbol = "bolt.horizontal.circle"
    public let actionTitle = "Lancer"

    /// Vibe Check turns this off so that a default run never asks for the administrator password.
    public var autoSelectsPasswordTasks: Bool
    /// Vibe Check's own subset: periodic scripts and login items only (purgeable space has no public API).
    public var vibeCheckSubset: Bool
    public var history: MaintenanceHistory

    public init(autoSelectsPasswordTasks: Bool = true, vibeCheckSubset: Bool = false, history: MaintenanceHistory = .init()) {
        self.autoSelectsPasswordTasks = autoSelectsPasswordTasks
        self.vibeCheckSubset = vibeCheckSubset
        self.history = history
    }

    static let launchRoots: [(String, LaunchItem.Scope)] = [
        ("/Library/LaunchAgents", .globalAgent), ("/Library/LaunchDaemons", .daemon),
    ]

    enum Key {
        static let removeUserAgent = "launchd.remove"
        static let removeLoginItem = "loginitem.remove"
        static let disableLoginItem = "loginitem.disable"
        static let enableLoginItem = "loginitem.enable"
        static let vacuumMail = "mail.vacuum"
    }

    static let taskPrefix = "performance.task."

    /// Stops a job and sets its root-owned plist aside in `ActionExecutor.rootTrash` (never a user-writable folder).
    /// $1 plist, $2 its physical parent (checked at run time), $3 holding area, $4 launchctl domain.
    static let removeScript = ActionExecutor.parentGuard + "\n" + "/bin/launchctl bootout \"$4\" \"$1\" >/dev/null 2>&1\n"
        + ActionExecutor.moveToRootTrash
    /// Stops the job and disables it persistently ($1 domain, $2 plist, $3 label). Never an Apple label.
    static let disableScript = "case \"$3\" in com.apple.*|\"\") exit 2;; esac; /bin/launchctl bootout \"$1\" \"$2\" >/dev/null 2>&1; /bin/launchctl disable \"$1/$3\""
    /// Re-enables the job and loads it; loading fails harmlessly when it is already loaded.
    static let enableScript = "case \"$3\" in com.apple.*|\"\") exit 2;; esac; /bin/launchctl enable \"$1/$3\" && { /bin/launchctl bootstrap \"$1\" \"$2\" >/dev/null 2>&1 || true; }"

    /// The admin action removing a /Library launchd job (Performance, Nettoyage, Applications).
    static func removeCommand(plist: URL, domain: String, rootTrash: String = ActionExecutor.rootTrash) -> ItemAction {
        let parent = ActionExecutor.physicalParent(plist) ?? plist.deletingLastPathComponent().path
        return .command(executable: "/bin/sh", arguments: ["-c", removeScript, "sh", plist.path, parent, rootTrash, domain], admin: true)
    }

    public func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup] {
        progress(0, "Tâches de maintenance")
        let snapshots = vibeCheckSubset ? [] : Self.timeMachineSnapshots(in: Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).stdout)
        let env = MaintenanceEnvironment(home: context.home, snapshots: snapshots.count,
                                         mailRunning: Self.isMailRunning, freeRatio: Self.freeRatio(),
                                         fileExists: { FileManager.default.isExecutableFile(atPath: $0) },
                                         autoSelectsPasswordTasks: autoSelectsPasswordTasks, lastRuns: history.lastRuns)
        var maintenance = Self.maintenanceGroups(env)
        if vibeCheckSubset {
            maintenance = maintenance.filter { $0.id == "performance.maintenance" }
                .map { var g = $0; g.items = g.items.filter { $0.id == Self.taskPrefix + "periodic" }; return g }
        }
        if Task.isCancelled { return [] }

        progress(0.3, "Éléments de connexion")
        let login = Self.loginGroup(LoginItems.list(), disabled: history.disabledLoginItems, appFolders: Self.appFolders(home: context.home))
        if Task.isCancelled { return [] }
        if vibeCheckSubset {
            progress(1, "Terminé")
            return (maintenance + [login]).map { $0.pruned() }.filter { !$0.isEmpty }
        }

        progress(0.5, "Agents de lancement")
        let roots = [(context.home.appendingPathComponent("Library/LaunchAgents"), LaunchItem.Scope.userAgent)]
            + Self.launchRoots.map { (URL(fileURLWithPath: $0.0), $0.1) }
        let launch = Self.launchGroup(roots: roots, context: context, status: LaunchdStatus.read())
        progress(1, "Terminé")
        return (maintenance + [login, launch]).map { $0.pruned() }.filter { !$0.isEmpty }
    }

    public func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport {
        let history = history
        let runnable = Self.reversibleFirst(items)
        let kept = Set(runnable.map(\.id))
        var report = ActionExecutor(remover: context.remover).run(runnable) { item, key in
            try Self.runCustom(item, key: key, remover: context.remover, history: history)
        }
        report.log += items.filter { !kept.contains($0.id) }.map { "Non supprimé : \($0.name) est désactivé à la place (réversible)" }
        recordHistory(report, dryRun: context.dryRun)
        return report
    }

    /// Ids of the reversible toggles ("Désactiver"/"Réactiver") of login items and launchd jobs.
    static let togglePrefixes = ["performance.launchd.disable.", "performance.launchd.enable.",
                                 "performance.login.disable.", "performance.login.enable."]

    /// One action per target: a login item or launchd removal is dropped when a toggle of the same app or plist
    /// is selected too, so that only the reversible one runs.
    static func reversibleFirst(_ items: [ResultItem]) -> [ResultItem] {
        func isToggle(_ i: ResultItem) -> Bool { togglePrefixes.contains(where: i.id.hasPrefix) }
        let toggled = Set(items.filter(isToggle).compactMap(\.url?.path))
        return items.filter { i in
            isToggle(i) || !(i.id.hasPrefix("performance.launchd.") || i.id.hasPrefix("performance.login."))
                || !toggled.contains(i.url?.path ?? "")
        }
    }

    /// Remembers the tasks that ran (weekly rule). Also called by the app for admin tasks run by a shared `AdminCollector`.
    public func recordHistory(_ report: ExecutionReport, dryRun: Bool) {
        guard !dryRun else { return }
        let keys = report.processed.filter { $0.hasPrefix(Self.taskPrefix) }.map { String($0.dropFirst(Self.taskPrefix.count)) }
        if !keys.isEmpty { history.record(keys) }
    }

    public func appDependency(of item: ResultItem) -> AppDependency? {
        item.action == .custom(Key.vacuumMail) ? AppDependency(name: "Mail", bundleID: "com.apple.mail") : nil
    }

    static func runCustom(_ item: ResultItem, key: String, remover: SafeRemover, history: MaintenanceHistory = .init()) throws {
        switch key {
        case Key.removeUserAgent:
            guard let url = item.url else { throw RemovalError.failed(item.name, "plist introuvable") }
            Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path]) // fails harmlessly if not loaded
            if let f = remover.remove([url], mode: .trash).failures.first { throw RemovalError.failed(url.path, f.1) }
        case Key.removeLoginItem:
            if !LoginItems.remove(name: item.name, url: item.url) {
                throw RemovalError.failed(item.name, "élément de connexion introuvable")
            }
        case Key.disableLoginItem:
            guard let url = item.url else { throw RemovalError.failed(item.name, "élément de connexion introuvable") }
            let entries = LoginItems.list()
            let hidden = (entries.first { $0.url?.path == url.path } ?? entries.first { $0.name == item.name })?.hidden ?? false
            guard LoginItems.remove(name: item.name, url: url) else {
                throw RemovalError.failed(item.name, "élément de connexion introuvable")
            }
            history.setLoginItem(url.path, disabled: true, hidden: hidden)
        case Key.enableLoginItem:
            guard let url = item.url, FileManager.default.fileExists(atPath: url.path) else {
                throw RemovalError.failed(item.name, "app introuvable")
            }
            guard LoginItems.add(url, hidden: history.hiddenLoginItems.contains(url.path)) else {
                throw RemovalError.failed(item.name, "ajout refusé par macOS")
            }
            history.setLoginItem(url.path, disabled: false)
        case Key.vacuumMail:
            guard let url = item.url else { throw RemovalError.failed(item.name, "base Mail introuvable") }
            try speedUpMail(url, mailRunning: isMailRunning)
        default:
            throw RemovalError.failed(item.name, "action non prise en charge")
        }
    }

    /// Speed Up Mail: a copy of the Envelope Index goes to the Trash first, then `VACUUM`,
    /// then Spotlight re-imports the Mail folder (a failed re-import does not fail the task).
    static func speedUpMail(_ index: URL, mailRunning: Bool,
                            backUp: (URL) throws -> Void = Browsers.backUpToTrash,
                            sqlite: (URL) -> ShellResult = { Shell.run("/usr/bin/sqlite3", [$0.path, "VACUUM;"]) },
                            reimport: (URL) -> Void = { Shell.run("/usr/bin/mdimport", [$0.path]) }) throws {
        if mailRunning { throw RemovalError.failed("Mail", "quittez Mail puis réessayez") }
        try backUp(index)
        let r = sqlite(index)
        if !r.ok { throw RemovalError.failed(index.path, r.stderr.isEmpty ? "sqlite3 code \(r.status)" : r.stderr) }
        // .../Mail/V<n>/MailData/Envelope Index → .../Mail/V<n>
        reimport(index.deletingLastPathComponent().deletingLastPathComponent())
    }

    // MARK: - Maintenance

    struct MaintenanceEnvironment {
        var home: URL
        var snapshots: Int
        var mailRunning: Bool
        /// Free space for important usage / total, on the boot volume.
        var freeRatio: Double
        var fileExists: (String) -> Bool
        var autoSelectsPasswordTasks = true
        var lastRuns: [String: Date] = [:]
        var now = Date()
        var uid: uid_t = getuid()

        /// Weekly maintenance rule: due when never run or run more than `days` ago.
        func due(_ key: String, days: Double) -> Bool {
            guard let last = lastRuns[key] else { return true }
            return now.timeIntervalSince(last) >= days * 86_400
        }
    }

    /// Maintenance tasks, then the RAM and Time Machine tasks in groups of their own (one tile each).
    static func maintenanceGroups(_ env: MaintenanceEnvironment) -> [ResultGroup] {
        // Harmless: nothing to undo (a cache emptied, an index rebuilt), so no "Irréversible" mark in the review.
        func task(_ key: String, _ name: String, _ detail: String, _ symbol: String, _ action: ItemAction,
                  auto: Bool, url: URL? = nil, harmless: Bool = false) -> ResultItem {
            let last = env.lastRuns[key].map { " Dernière exécution : \(Junk.format($0))." } ?? ""
            var item = ResultItem(id: taskPrefix + key, name: name, detail: detail + last, url: url, symbol: symbol,
                                  action: action, autoSelect: auto)
            item.commandIsHarmless = harmless
            return item
        }
        let password = env.autoSelectsPasswordTasks
        var ram: [ResultItem] = [], timeMachine: [ResultItem] = [], items: [ResultItem] = []
        if env.fileExists("/usr/sbin/purge") {
            ram.append(task("freeRAM", "Libérer de la RAM",
                            "Vide les caches disque inactifs de la mémoire. Effet temporaire.", "memorychip",
                            .command(executable: "/usr/sbin/purge", arguments: [], admin: true), auto: password && env.due("freeRAM", days: 7),
                            harmless: true))
        }
        items.append(task("flushDNS", "Vider le cache DNS",
                          "Oublie les adresses de sites mémorisées par le Mac, qui les redemande au prochain accès. "
                              + "Corrige les sites qui ne se chargent plus après un changement de réseau ou de DNS. Sans risque.", "network",
                          .command(executable: "/bin/sh",
                                   arguments: ["-c", "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"],
                                   admin: true), auto: password && env.due("flushDNS", days: 7), harmless: true))
        if env.snapshots > 0 {
            timeMachine.append(task("thinSnapshots", "Alléger les instantanés Time Machine",
                                    "\(env.snapshots) instantané(s) local(aux). Demande à macOS d'en supprimer pour libérer jusqu'à 1 Go.",
                                    "clock.arrow.circlepath",
                                    .command(executable: "/usr/bin/tmutil",
                                             arguments: ["thinlocalsnapshots", "/", "1073741824", "3"], admin: false),
                                    auto: env.freeRatio < 0.15))
        }
        if let index = mailEnvelopeIndex(home: env.home) {
            let size = FileSizer.format(FileSizer.size(of: index))
            items.append(task("speedUpMail", "Accélérer Mail",
                              env.mailRunning ? "Quittez Mail : la base des messages (\(size)) ne peut être compactée que Mail fermé."
                                              : "Compacte la base des messages de Mail (\(size)) pour une recherche plus rapide. Une copie part d'abord à la Corbeille.",
                              "envelope", .custom(Key.vacuumMail), auto: !env.mailRunning && env.due("speedUpMail", days: 30), url: index))
        }
        // Prudent: a multi-hour reindex is only recommended again 30 days after one run from here, never on a first scan.
        let reindexDue = env.lastRuns["reindexSpotlight"] != nil && env.due("reindexSpotlight", days: 30)
        items.append(task("reindexSpotlight", "Réindexer Spotlight",
                          "Reconstruit l'index de Spotlight, la recherche de macOS (⌘ Espace, recherche du Finder et de Mail). "
                              + "Utile si des fichiers ne sont plus trouvés. Peut prendre plusieurs heures, la recherche reste incomplète pendant ce temps.",
                          "magnifyingglass",
                          .command(executable: "/usr/bin/mdutil", arguments: ["-E", "/"], admin: true), auto: password && reindexDue,
                          harmless: true))
        items.append(task("resetPermissions", "Réparer les permissions du dossier personnel",
                          "Réinitialise les permissions et ACL de votre dossier utilisateur. Utile en dépannage.",
                          "lock.rotation",
                          .command(executable: "/usr/sbin/diskutil",
                                   arguments: ["resetUserPermissions", "/", String(env.uid)], admin: true), auto: false))
        if env.fileExists("/usr/sbin/periodic") {
            items.append(task("periodic", "Lancer les scripts de maintenance",
                              "Exécute les scripts periodic quotidiens, hebdomadaires et mensuels.", "calendar.badge.clock",
                              .command(executable: "/usr/sbin/periodic", arguments: ["daily", "weekly", "monthly"], admin: true),
                              auto: false, harmless: true))
        }
        return [
            ResultGroup(id: "performance.maintenance", title: "Maintenance hebdomadaire",
                        subtitle: "Tâches recommandées selon leur dernière exécution. Certaines demandent votre mot de passe.",
                        symbol: "wrench.and.screwdriver", items: items),
            ResultGroup(id: "performance.ram", title: "Libérer la RAM",
                        subtitle: "Rend de la mémoire disponible aux apps. Demande votre mot de passe.", symbol: "memorychip", items: ram),
            ResultGroup(id: "performance.timeMachine", title: "Instantanés Time Machine",
                        subtitle: "Instantanés locaux qui occupent de l'espace sur le disque de démarrage.", symbol: "clock.arrow.circlepath",
                        items: timeMachine),
        ]
    }

    static func timeMachineSnapshots(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }

    /// `~/Library/Mail/V<highest>/MailData/Envelope Index`. Needs Full Disk Access; nil otherwise.
    static func mailEnvelopeIndex(home: URL) -> URL? {
        let mail = home.appendingPathComponent("Library/Mail")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: mail.path)) ?? []
        let latest = versions.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
            return (n, name)
        }.max { $0.0 < $1.0 }
        guard let latest else { return nil }
        let index = mail.appendingPathComponent("\(latest.1)/MailData/Envelope Index")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    static var isMailRunning: Bool { Shell.run("/usr/bin/pgrep", ["-x", "Mail"]).ok }

    static func freeRatio() -> Double {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                        .volumeTotalCapacityKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage, let total = v?.volumeTotalCapacity, total > 0 else { return 1 }
        return Double(free) / Double(total)
    }

    // MARK: - Login items

    /// Folders searched for a login item whose location does not resolve.
    static func appFolders(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), home.appendingPathComponent("Applications")]
    }

    /// The app a login item opens: its resolved location when it exists, else `<name>.app` in `appFolders`
    /// (an alias macOS no longer resolves although the app is installed).
    static func installedApp(_ e: LoginItems.Entry, appFolders: [URL]) -> URL? {
        if let url = e.url, FileManager.default.fileExists(atPath: url.path) { return url }
        let name = e.name.hasSuffix(".app") ? String(e.name.dropLast(4)) : e.name
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return appFolders.map { $0.appendingPathComponent(name + ".app") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One action per login item, never selected: a reversible "Désactiver" for an installed app, "Supprimer" only
    /// for an entry whose app is gone or cannot be located, and "Réactiver" for the apps Vibe Cleaner disabled
    /// earlier (`disabled`: their paths).
    static func loginGroup(_ entries: [LoginItems.Entry], disabled: [String] = [],
                           appFolders: [URL] = appFolders(home: URL(fileURLWithPath: NSHomeDirectory()))) -> ResultGroup {
        var present: [(String, URL)] = [], items: [ResultItem] = [], seen = Set<String>()
        for e in entries {
            if let app = installedApp(e, appFolders: appFolders) {
                if seen.insert(app.path).inserted { present.append((e.name, app)) }
                continue
            }
            items.append(ResultItem(id: "performance.login.\(e.url?.path ?? e.name)", name: e.name,
                                    detail: e.url.map { "Introuvable : \($0.path)" } ?? "Emplacement non résolu",
                                    url: e.url, symbol: e.url == nil ? "questionmark.circle" : "exclamationmark.triangle",
                                    action: .custom(Key.removeLoginItem), autoSelect: false))
        }
        let disable = present.map { name, url in
            ResultItem(id: "performance.login.disable.\(url.path)", name: name, detail: "Ne s'ouvrira plus à la connexion — réactivable ici",
                       url: url, symbol: "pause.circle", action: .custom(Key.disableLoginItem), autoSelect: false)
        }
        let listed = Set(present.map(\.1.path))
        let enable = disabled.filter { !listed.contains($0) }.map { path in
            let url = URL(fileURLWithPath: path)
            return ResultItem(id: "performance.login.enable.\(path)", name: url.deletingPathExtension().lastPathComponent,
                              detail: FileManager.default.fileExists(atPath: path) ? "Désactivé par Vibe Cleaner — \(path)" : "Introuvable : \(path)",
                              url: url, symbol: "play.circle", action: .custom(Key.enableLoginItem), autoSelect: false)
        }
        return ResultGroup(id: "performance.login", title: "Éléments de connexion",
                           subtitle: "Apps ouvertes à chaque connexion. Les éléments d'arrière-plan ajoutés par les apps se gèrent dans Réglages Système > Général > Ouverture.",
                           symbol: "person.crop.circle.badge.checkmark",
                           groups: [ResultGroup(id: "performance.login.disable", title: "Désactiver à la connexion", symbol: "pause.circle", items: disable).oneByOne(),
                                    ResultGroup(id: "performance.login.enable", title: "Réactiver", symbol: "play.circle", items: enable).oneByOne()],
                           items: items, autoSelect: false)
    }

    // MARK: - Launch agents

    static func launchItems(in dir: URL, scope: LaunchItem.Scope, context: ModuleContext) -> [LaunchItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.sorted().compactMap { name in
            let url = dir.appendingPathComponent(name)
            return context.isExcluded(url) ? nil : LaunchItem.parse(url, scope: scope)
        }
    }

    static func launchGroup(roots: [(URL, LaunchItem.Scope)], context: ModuleContext, uid: uid_t = getuid(),
                            status: [String: LaunchdStatus] = [:]) -> ResultGroup {
        let titles: [LaunchItem.Scope: (String, String)] = [
            .userAgent: ("Agents utilisateur", "person"), .globalAgent: ("Agents de tous les utilisateurs", "person.2"),
            .daemon: ("Daemons système", "gearshape.2"),
        ]
        var disable: [ResultItem] = [], enable: [ResultItem] = []
        var groups = roots.map { dir, scope in
            let launch = launchItems(in: dir, scope: scope, context: context)
            for item in launch where item.readable && !item.isBroken {
                let domain = item.domain(uid: uid)
                let off = status[domain]?.disabled.contains(item.label) == true
                let action = ItemAction.command(executable: "/bin/sh", arguments: ["-c", off ? enableScript : disableScript, "sh",
                                                                                   domain, item.plist.path, item.label],
                                                admin: item.scope.needsAdmin)
                let r = ResultItem(id: "performance.launchd.\(off ? "enable" : "disable").\(item.plist.path)", name: item.label,
                                   detail: off ? "Désactivé dans launchd — le réactiver et le charger" : "L'arrêter et l'empêcher de redémarrer",
                                   url: item.plist, symbol: off ? "play.circle" : "pause.circle", action: action, autoSelect: false)
                if off { enable.append(r) } else { disable.append(r) }
            }
            let items = launch.map { resultItem($0, uid: uid, status: status[$0.domain(uid: uid)]) }
            let (title, symbol) = titles[scope]!
            // Ticked one by one: a card tick would remove every third-party job (updaters, tunnels, helpers).
            // Broken user agents stay in the smart selection through `autoSelect`.
            return ResultGroup(id: "performance.launchd.\(scope.rawValue)", title: title, subtitle: dir.path,
                               symbol: symbol, items: items).oneByOne()
        }
        groups.append(ResultGroup(id: "performance.launchd.disable", title: "Désactiver au démarrage", subtitle: "Réversible : réactivable ici",
                                  symbol: "pause.circle", items: disable, autoSelect: false).oneByOne())
        groups.append(ResultGroup(id: "performance.launchd.enable", title: "Réactiver", subtitle: "Jobs désactivés dans launchd",
                                  symbol: "play.circle", items: enable, autoSelect: false).oneByOne())
        return ResultGroup(id: "performance.launchd", title: "Agents de lancement",
                           subtitle: "Programmes lancés en arrière-plan par launchd. Les agents utilisateur cassés sont sélectionnés.",
                           symbol: "gearshape.2", groups: groups)
    }

    static func resultItem(_ item: LaunchItem, uid: uid_t, status: LaunchdStatus? = nil) -> ResultItem {
        var parts: [String] = []
        if !item.readable {
            parts.append("Plist illisible")
        } else if item.isBroken {
            parts.append("Cassé : programme introuvable (\(item.program ?? ""))")
        } else {
            if let app = item.parentApp { parts.append(app.deletingPathExtension().lastPathComponent) }
            else if let p = item.program { parts.append(p) }
            else if !item.hasBundleProgram { parts.append("Aucun programme déclaré") }
            if let pub = item.publisher { parts.append(pub == "Apple" ? "Apple" : "Tiers (\(pub))") }
        }
        if let status {
            switch status.loaded[item.label] {
            case nil: parts.append("non chargé")
            case 0: parts.append("chargé")
            case let pid?: parts.append("en cours (PID \(pid))")
            }
            if status.disabled.contains(item.label) { parts.append("désactivé dans launchd") }
        }
        if item.disabled { parts.append("désactivé") }
        if item.keepAlive { parts.append("toujours actif") } else if item.runAtLoad { parts.append("au démarrage") }
        if item.periodic { parts.append("périodique") }

        let action: ItemAction = item.scope.needsAdmin
            ? removeCommand(plist: item.plist, domain: item.domain(uid: uid))
            : .custom(Key.removeUserAgent)
        let broken = item.isBroken
        // Only a broken user agent is selected: a /Library job would ask for the administrator password.
        return ResultItem(id: "performance.launchd.\(item.plist.path)", name: item.label, detail: parts.joined(separator: " · "),
                          url: item.plist, size: FileSizer.size(of: item.plist),
                          symbol: broken ? "exclamationmark.triangle" : "gearshape",
                          action: action, autoSelect: broken && !item.scope.needsAdmin && !(item.program ?? "").hasPrefix("/Volumes/"))
    }
}

extension ResultGroup {
    /// This group and its subgroups with `bulkSelectable` off: a tick on a parent group or a card leaves them alone.
    func oneByOne() -> ResultGroup {
        var g = self
        g.bulkSelectable = false
        g.groups = groups.map { $0.oneByOne() }
        return g
    }
}
