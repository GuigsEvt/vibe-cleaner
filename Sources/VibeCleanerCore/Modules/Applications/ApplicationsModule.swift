import AppKit
import Foundation
import Security

/// Uninstaller: inventory of installed apps with their associated files, unused apps and leftovers of deleted apps.
public struct ApplicationsModule: ScanModule {
    public let id = "applications"
    public let title = "Applications"
    public let subtitle = "Désinstalle proprement les apps avec tous leurs fichiers et retrouve les restes d'apps déjà supprimées."
    public let symbol = "square.grid.2x2"
    public let actionTitle = "Supprimer"

    static let selfBundleID = "ai.flowpace.vibecleaner"
    public var unusedDays = 180
    /// Set by the app from its Full Disk Access probe. False: Downloads, Desktop and Documents are never read
    /// (each would show a macOS prompt during the scan).
    public var fullDiskAccess = false

    /// Test seams; nil means the real system locations.
    var applicationDirs: [URL]?
    var systemApplicationDirs: [URL] = [URL(fileURLWithPath: "/System/Applications")]
    var localLibrary = URL(fileURLWithPath: "/Library")
    var receiptsDir = URL(fileURLWithPath: "/var/db/receipts")
    var darwinDirs = [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap(Junk.confstrPath)
    var binDirs = AppFootprint.defaultBinDirs
    var loginItems: [LoginItems.Entry]?
    var findInstallers: @Sendable (URL) -> [URL] = InstallerSearch.spotlight
    /// Apps outside the Applications folders; nil when tests give the app folders.
    var findApps: (@Sendable (URL) -> [URL])? = AppInventory.spotlightApps
    var listSystemExtensions: @Sendable () -> String = Plugins.listSystemExtensions
    var softwareUpdatePlist = SystemUpdates.plist
    /// Asks the App Store and the Sparkle feeds for newer versions. Off by default (tests, CLI); the app turns it on.
    public var checkUpdates = false
    var fetchUpdate: AppUpdates.Fetch = AppUpdates.fetch
    var appleSilicon = AppCompatibility.isAppleSilicon
    var rosetta = AppCompatibility.hasRosetta

    public init() {}

    // MARK: Inventory

    /// Installed apps from /Applications, ~/Applications (one subfolder level) and /System/Applications (marked `isSystem`).
    public func installedApps(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [InstalledApp] {
        let dirs = applicationDirs ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        let elsewhere = applicationDirs == nil ? findApps.map { AppInventory.filterSpotlightApps($0(home), home: home, fullDiskAccess: fullDiskAccess) } ?? [] : []
        for (urls, system) in [(AppInventory.appURLs(in: dirs) + elsewhere, false), (AppInventory.appURLs(in: systemApplicationDirs), true)] {
            for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
                if let app = AppInventory.load(url, isSystem: system) { apps.append(app) }
            }
        }
        return apps
    }

    func footprintFinder(home: URL, installed: [InstalledApp]) -> AppFootprint {
        AppFootprint(home: home, localLibrary: localLibrary, receiptsDir: receiptsDir, darwinDirs: darwinDirs, binDirs: binDirs,
                     loginItems: loginItems ?? LoginItems.list(), installed: installed, downloads: fullDiskAccess)
    }

    /// Group ids of a single app ("all:<bundle>", "vendor:Adobe:<bundle>"…), where "Réinitialiser" applies.
    public static let appGroupPrefixes = ["all:", "unused:", "incompatible:", "suspicious:", "vendor:", "store:"]
    public static func isAppGroup(_ id: String) -> Bool { appGroupPrefixes.contains { id.hasPrefix($0) } }
    /// Cards that list whole apps (bundle and data): their action reads "Désinstaller".
    public static let uninstallGroupIDs: Set<String> = ["applications.unused", "applications.incompatible", "applications.suspicious",
                                                        "applications.steam", "applications.all"]
    /// `ResultGroup.tags` keys of an app group: where it was installed from, and its vendor.
    public static let sourceTag = "Source", vendorTag = "Éditeur"
    /// The bundle of an app group ("all:/Applications/Foo.app" → /Applications/Foo.app).
    public static func appURL(groupID: String) -> URL? {
        guard isAppGroup(groupID), let slash = groupID.firstIndex(of: "/") else { return nil }
        return URL(fileURLWithPath: String(groupID[slash...]))
    }

    // MARK: Scan

    public func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup] {
        progress(0, "Inventaire des applications")
        var apps = installedApps(home: context.home)
        if Task.isCancelled { return [] }

        // Network checks run alongside the disk work; a slow server delays only the end of the scan.
        let candidates = checkUpdates ? apps.filter { !$0.isSystem && !context.isExcluded($0.url) } : []
        let fetch = fetchUpdate
        let updateCheck = Task { await AppUpdates.find(candidates, fetch: fetch) }
        defer { updateCheck.cancel() }

        progress(0.15, "Taille et signature des applications")
        let removable = apps.indices.filter { !apps[$0].isProtected && !context.isExcluded(apps[$0].url) }
        let checked = await withTaskGroup(of: (Int, Int64, String?).self) { group in
            for i in removable {
                let url = apps[i].url
                group.addTask { Task.isCancelled ? (i, 0, nil) : (i, FileSizer.size(of: url), Self.signatureIssue(url)) }
            }
            var out: [Int: (Int64, String?)] = [:]
            for await (i, s, sig) in group { out[i] = (s, sig) }
            return out
        }
        for (i, c) in checked { apps[i].size = c.0 }
        if Task.isCancelled { return [] }

        progress(0.45, "Fichiers associés")
        let finder = footprintFinder(home: context.home, installed: apps)
        var all: [ResultGroup] = [], unused: [ResultGroup] = [], incompatible: [ResultGroup] = [], suspicious: [ResultGroup] = []
        for (n, i) in removable.enumerated() {
            if Task.isCancelled { return [] }
            let app = apps[i]
            progress(0.45 + 0.35 * Double(n) / Double(max(removable.count, 1)), app.name)
            let items = [bundleItem(app, home: context.home)] + fileItems(app, finder.footprint(of: app), context: context)
                + extraItems(app, finder: finder)
            let vendor = AppOrigin.vendor(app), store = AppOrigin.store(app, home: context.home)
            func group(_ prefix: String, _ note: String? = nil) -> ResultGroup {
                var g = ResultGroup(id: "\(prefix):\(app.url.path)", title: app.name,
                                    subtitle: [note, Self.describe(app)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                    symbol: "app", items: items, autoSelect: false)
                g.tags = [Self.sourceTag: store.rawValue, Self.vendorTag: vendor]
                return g
            }
            all.append(group("all"))
            if app.isUnused(days: unusedDays) { unused.append(group("unused")) }
            if let issue = AppCompatibility.issue(app, appleSilicon: appleSilicon, rosetta: rosetta) { incompatible.append(group("incompatible", issue)) }
            if let issue = checked[i]?.1 { suspicious.append(group("suspicious", issue)) }
        }

        progress(0.8, "Restes d'apps supprimées")
        let trashed = TrashedApps.find(home: context.home, installed: apps, finder: finder)
        let claimed = Set(trashed.flatMap { $0.leftovers.map(\.path) })
        let systemExtensions = Plugins.parseSystemExtensions(listSystemExtensions())
        let components = Leftovers.componentIDs(libraries: [context.home.appendingPathComponent("Library"), localLibrary],
                                                systemExtensions: systemExtensions, receiptsDir: receiptsDir)
        let leftovers = leftoverGroups(Leftovers.find(home: context.home, localLibrary: localLibrary, installed: apps, componentIDs: components)
            .filter { !claimed.contains($0.url.path) }, context: context)
        progress(0.9, "Installeurs, plug-ins et jeux")
        let installers = installerItems(InstallerSearch.filter(findInstallers(context.home), home: context.home, fullDiskAccess: fullDiskAccess), finder: finder, apps: apps,
                                        context: context)
        let plugins = pluginGroups(home: context.home, context: context, systemExtensions: systemExtensions)
        let steam = steamGroups(home: context.home, apps: apps, context: context)
        let updates = SystemUpdates.pending(plist: softwareUpdatePlist)
        if checkUpdates { progress(0.95, "Mises à jour des applications") }
        let appUpdates = await updateCheck.value
        progress(1, "Terminé")

        let byName: (ResultGroup, ResultGroup) -> Bool = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return [
            ResultGroup(id: "applications.updates", title: "Mises à jour d'apps",
                        subtitle: "Versions plus récentes publiées sur l'App Store ou par l'éditeur. Ouvrez l'App Store ou l'app pour les installer.",
                        symbol: "arrow.down.circle", items: appUpdates.map(AppUpdates.item), autoSelect: false),
            ResultGroup(id: "applications.unused", title: "Applications inutilisées",
                        subtitle: "Apps que vous n'avez pas ouvertes depuis plus de \(unusedDays / 30) mois.", symbol: "clock.badge.questionmark",
                        groups: unused.sorted(by: byName), autoSelect: false),
            ResultGroup(id: "applications.leftovers", title: "Restes d'apps supprimées",
                        subtitle: "Préférences, caches et données d'apps qui ne sont plus installées.", symbol: "puzzlepiece.extension",
                        groups: leftovers),
            ResultGroup(id: "applications.trashed", title: "Restes d'apps mises à la Corbeille",
                        subtitle: "Apps glissées dans la Corbeille : leurs préférences, caches et agents sont restés sur le Mac.",
                        symbol: "trash", groups: trashed.map { trashedGroup($0, context: context) }, autoSelect: false),
            ResultGroup(id: "applications.installers", title: "Installeurs inutilisés",
                        subtitle: "Images disque et paquets d'installation rangés dans votre dossier personnel (hors Téléchargements).",
                        symbol: "shippingbox", items: installers, autoSelect: false),
            ResultGroup(id: "applications.incompatible", title: "Apps 32 bits ou incompatibles",
                        subtitle: "Apps qui ne peuvent pas s'ouvrir sur ce Mac, ou seulement à travers Rosetta.", symbol: "exclamationmark.triangle",
                        groups: incompatible.sorted(by: byName), autoSelect: false),
            ResultGroup(id: "applications.suspicious", title: "Apps suspectes",
                        subtitle: "Apps sans signature de code valide : leur origine ne peut pas être vérifiée.", symbol: "exclamationmark.shield",
                        groups: suspicious.sorted(by: byName), autoSelect: false),
            ResultGroup(id: "applications.plugins", title: "Plug-ins et extensions",
                        subtitle: "Plug-ins audio, Quick Look, économiseurs d'écran, panneaux de préférences et extensions système.",
                        symbol: "puzzlepiece", groups: plugins, autoSelect: false),
            ResultGroup(id: "applications.steam", title: "Jeux Steam",
                        subtitle: "Jeux installés par Steam. Quittez Steam avant de les supprimer, ou désinstallez-les depuis Steam.",
                        symbol: "gamecontroller", groups: steam, autoSelect: false),
            ResultGroup(id: "applications.macos", title: "Mises à jour macOS",
                        subtitle: "Mises à jour trouvées par macOS lors de sa dernière vérification. Installez-les depuis Réglages Système.",
                        symbol: "arrow.down.app", items: updates.map {
                            ResultItem(id: "applications.macos.\($0.id)", name: $0.name,
                                       detail: "Réglages Système > Général > Mise à jour de logiciels", symbol: "arrow.down.app",
                                       action: .none, autoSelect: false)
                        }, autoSelect: false),
            ResultGroup(id: "applications.all", title: "Toutes les applications",
                        subtitle: "Chaque app avec son bundle et tous ses fichiers associés. Filtrez par source ou par éditeur.", symbol: "square.grid.2x2",
                        groups: all.sorted(by: byName), autoSelect: false),
        ].map { g in
            var g = g.pruned()
            if g.groups.contains(where: { !$0.tags.isEmpty }) { g.facetKeys = [Self.sourceTag, Self.vendorTag] }
            // Lists of whole apps are never ticked in bulk, from any card, menu or Vibe Check: apps are picked one by one.
            if Self.uninstallGroupIDs.contains(g.id) { g.bulkSelectable = false }
            return g
        }
    }

    /// Why the bundle's code signature cannot be trusted, or nil. Checks the executable and Info.plist only.
    static func signatureIssue(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return "Aucune signature de code" }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard (info as? [String: Any])?[kSecCodeInfoIdentifier as String] != nil else { return "Aucune signature de code" }
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess
        return valid ? nil : "Signature invalide : l'app a été modifiée depuis sa signature"
    }

    static func describe(_ app: InstalledApp) -> String {
        // An app outside the Applications folders says where it is: it is easy to forget a tool unzipped in a project.
        let dir = app.url.deletingLastPathComponent().path
        let elsewhere = dir == "/Applications" || dir.hasPrefix("/Applications/") || dir.hasPrefix("/System/")
            || dir.hasPrefix(NSHomeDirectory() + "/Applications") ? nil : "Dans " + (dir as NSString).abbreviatingWithTildeInPath
        return [app.version.flatMap { $0.isEmpty ? nil : "Version \($0)" }, app.publisher ?? app.teamID, app.source == .appStore ? "App Store" : nil, elsewhere]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func bundleItem(_ app: InstalledApp, home: URL) -> ResultItem {
        ResultItem(id: app.url.path, name: app.name, detail: Self.describe(app), url: app.url, size: app.size,
                   date: app.lastUsed, symbol: "app",
                   action: .delete(app.url, mode: .trash, admin: Self.needsAdmin(app.url, home: home)))
    }

    /// Item ids are "<bundle path>|<file path>" so `execute` knows which app to quit first.
    func fileItems(_ app: InstalledApp, _ files: [URL], context: ModuleContext) -> [ResultItem] {
        var items: [ResultItem] = []
        var receipts = Set<String>()
        for url in files where !context.isExcluded(url) {
            if url.deletingLastPathComponent().standardizedFileURL.path == receiptsDir.standardizedFileURL.path {
                receipts.insert(url.deletingPathExtension().lastPathComponent)
                continue
            }
            var item = ResultItem.file(url, admin: Self.needsAdmin(url, home: context.home))
            item = ResultItem(id: "\(app.url.path)|\(url.path)", name: item.name, detail: item.detail, url: url, size: item.size,
                              date: item.date, action: launchdAction(url, home: context.home) ?? item.action)
            items.append(item)
        }
        for pkg in receipts.sorted() {
            items.append(ResultItem(id: "\(app.url.path)|receipt:\(pkg)", name: pkg, detail: "Reçu d'installation (pkgutil --forget)",
                                    symbol: "shippingbox", action: .command(executable: "/usr/sbin/pkgutil", arguments: ["--forget", pkg], admin: true)))
        }
        return items
    }

    /// Launchd jobs are stopped before their plist goes to the Trash, as in Performance:
    /// user agents in-process, /Library jobs in the admin batch.
    func launchdAction(_ url: URL, home: URL, uid: uid_t = getuid()) -> ItemAction? {
        let dir = url.deletingLastPathComponent().standardizedFileURL.path
        if dir == home.appendingPathComponent("Library/LaunchAgents").standardizedFileURL.path {
            return .custom(PerformanceModule.Key.removeUserAgent)
        }
        let domain: String
        switch dir {
        case localLibrary.appendingPathComponent("LaunchDaemons").standardizedFileURL.path: domain = "system"
        case localLibrary.appendingPathComponent("LaunchAgents").standardizedFileURL.path: domain = "gui/\(uid)"
        default: return nil
        }
        return PerformanceModule.removeCommand(plist: url, domain: domain)
    }

    /// Dock icon (reported only: rewriting the Dock's preferences is not safe) and login items of the app.
    func extraItems(_ app: InstalledApp, finder: AppFootprint) -> [ResultItem] {
        var items = finder.loginItems(of: app).map { e in
            ResultItem(id: "\(app.url.path)|login:\(e.url?.path ?? e.name)", name: e.name, detail: "Élément de connexion",
                       url: e.url, symbol: "power", action: .custom(PerformanceModule.Key.removeLoginItem))
        }
        if finder.isInDock(app) {
            items.append(ResultItem(id: "\(app.url.path)|dock", name: "Icône du Dock",
                                    detail: "À retirer à la main : clic droit sur l'icône > Options > Garder dans le Dock",
                                    symbol: "dock.rectangle", action: .none, autoSelect: false))
        }
        return items
    }

    func leftoverGroups(_ hits: [Leftovers.Hit], context: ModuleContext) -> [ResultGroup] {
        Dictionary(grouping: hits.filter { !context.isExcluded($0.url) }, by: \.ownerID)
            .sorted { $0.key < $1.key }
            .map { owner, hits in
                ResultGroup(id: "leftover:\(owner)", title: owner, symbol: "questionmark.app.dashed", items: hits.map { hit in
                    var item = ResultItem.file(hit.url, admin: Self.needsAdmin(hit.url, home: context.home), autoSelect: hit.clear)
                    if let a = launchdAction(hit.url, home: context.home) { item.action = a }
                    return item
                })
            }
    }

    func trashedGroup(_ e: TrashedApps.Entry, context: ModuleContext) -> ResultGroup {
        ResultGroup(id: "trashed:\(e.app.url.path)", title: e.app.name,
                    subtitle: "Dans la Corbeille · \(e.leftovers.count) fichier(s) associé(s)", symbol: "app.dashed",
                    items: fileItems(e.app, e.leftovers, context: context), autoSelect: false)
    }

    func installerItems(_ urls: [URL], finder: AppFootprint, apps: [InstalledApp], context: ModuleContext) -> [ResultItem] {
        urls.filter { !context.isExcluded($0) }.map { url in
            let stem = url.deletingPathExtension().lastPathComponent
            let owner = apps.first { finder.isInstaller(stem, of: $0.name) }
            var item = ResultItem.file(url, admin: Self.needsAdmin(url, home: context.home), autoSelect: false)
            item.symbol = "shippingbox"
            if let owner { item.detail = "« \(owner.name) » est déjà installée · \(url.deletingLastPathComponent().path)" }
            return item
        }.sorted { $0.size > $1.size }
    }

    func pluginGroups(home: URL, context: ModuleContext, systemExtensions: [Plugins.SystemExtension]? = nil) -> [ResultGroup] {
        let found = Plugins.find(libraries: [home.appendingPathComponent("Library"), localLibrary]).filter { !context.isExcluded($0.url) }
        var groups = Plugins.kinds.map { kind in
            ResultGroup(id: "plugins.\(kind.id)", title: kind.title, symbol: kind.symbol, items: found.filter { $0.kind == kind.id }.map { p in
                var item = ResultItem.file(p.url, admin: Self.needsAdmin(p.url, home: home), autoSelect: false)
                item.detail = [p.bundleID, p.url.deletingLastPathComponent().path].compactMap { $0 }.joined(separator: " · ")
                return item
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, autoSelect: false)
        }
        let ext = systemExtensions ?? Plugins.parseSystemExtensions(listSystemExtensions())
        groups.append(ResultGroup(id: "plugins.sysext", title: "Extensions système",
                                  subtitle: "Se retirent avec l'app qui les a installées, ou dans Réglages Système > Général > Ouverture et extensions.",
                                  symbol: "cpu", items: ext.map { e in
                                      ResultItem(id: "plugins.sysext.\(e.bundleID)", name: e.name.isEmpty ? e.bundleID : e.name,
                                                 detail: "\(e.bundleID) \(e.version) · équipe \(e.teamID) · \(e.state)", symbol: "cpu",
                                                 action: .none, autoSelect: false)
                                  }, autoSelect: false))
        return groups
    }

    /// Item ids carry Steam's bundle path when it is installed, so the app asks to quit it first.
    func steamGroups(home: URL, apps: [InstalledApp], context: ModuleContext) -> [ResultGroup] {
        let steam = apps.first { $0.bundleID?.lowercased() == "com.valvesoftware.steam" }?.url.path
        return SteamLibrary.games(home: home).filter { !context.isExcluded($0.folder) }.map { g in
            let items = [g.folder, g.manifest].map { url in
                let file = ResultItem.file(url, admin: Self.needsAdmin(url, home: home), autoSelect: false)
                return ResultItem(id: steam.map { "\($0)|\(url.path)" } ?? url.path, name: file.name, detail: file.detail, url: url,
                                  size: file.size, date: file.date, symbol: "gamecontroller", action: file.action, autoSelect: false)
            }
            return ResultGroup(id: "steam:\(g.id)", title: g.name, subtitle: "Steam · jeu \(g.id)", symbol: "gamecontroller",
                               items: items, autoSelect: false)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Outside the home and owned by root → batched into the admin prompt.
    static func needsAdmin(_ url: URL, home: URL) -> Bool {
        if url.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path + "/") { return false }
        let owner = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber
        return owner?.intValue == 0
    }

    // MARK: Execute

    public func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport {
        // The same file can be listed under an app and in another category (plug-ins, installers).
        var seen = Set<String>()
        let unique = items.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            guard case .delete(let url, _, _) = item.action else { return true }
            return seen.insert("file:" + url.standardizedFileURL.path).inserted
        }
        var blocked = Set<String>()
        if !context.dryRun {
            let bundles = Set(unique.compactMap(Self.bundlePath(of:)))
            for path in bundles.sorted() {
                if Task.isCancelled { break }
                if !(await AppTerminator.quit(bundlePath: path)) { blocked.insert(path) }
            }
        }
        var report = ExecutionReport()
        var runnable: [ResultItem] = []
        for item in unique {
            if let b = Self.bundlePath(of: item), blocked.contains(b) {
                let name = URL(fileURLWithPath: b).deletingPathExtension().lastPathComponent
                report.failures.append((item.id, "« \(name) » est toujours ouverte et n'a pas pu être quittée. Quittez-la puis réessayez."))
            } else {
                runnable.append(item)
            }
        }
        // Pass 1: everything but user-owned bundles, admin bundles last in the one admin batch, so launchd jobs are
        // stopped and login items removed while the app is still in place. The batch is never deferred to a shared
        // collector: that would trash the bundle before its daemon is stopped.
        let isBundle: (ResultItem) -> Bool = { $0.url?.pathExtension == "app" && Self.bundlePath(of: $0) == $0.url?.path }
        let isAdmin: (ResultItem) -> Bool = {
            if case .delete(_, _, true) = $0.action { return true }
            if case .command(_, _, true) = $0.action { return true }
            return false
        }
        let first = runnable.filter { !isBundle($0) } + runnable.filter { isBundle($0) && isAdmin($0) }
        let executor = ActionExecutor(remover: context.remover)
        let custom: (ResultItem, String) throws -> Void = { item, key in try PerformanceModule.runCustom(item, key: key, remover: context.remover) }
        var r = ActionExecutor.$adminCollector.withValue(nil) { executor.run(first, custom: custom) }
        // Pass 2: a user-owned bundle stays when one of its launchd, login-item, receipt or other root steps failed
        // (prompt cancelled…): its daemon would otherwise keep running with the app gone.
        let failedIDs = Set(r.failures.map(\.id))
        let unstopped = Set(first.filter { failedIDs.contains($0.id) && !isBundle($0) }.filter { item in
            if isAdmin(item) { return true }
            if case .custom = item.action { return true }
            return false
        }.compactMap(Self.bundlePath(of:)))
        var second: [ResultItem] = []
        for item in runnable where isBundle(item) && !isAdmin(item) {
            if let b = Self.bundlePath(of: item), unstopped.contains(b) {
                r.failures.append((item.id, "App laissée en place : un de ses agents, éléments de connexion ou fichiers système n'a pas pu être retiré."))
            } else {
                second.append(item)
            }
        }
        r.merge(executor.run(second, custom: custom))
        report.processed += r.processed
        report.freedBytes += r.freedBytes
        report.failures += r.failures
        report.log += r.log
        // cfprefsd caches preferences in memory and would write a removed plist back.
        let done = Set(r.processed)
        if !context.dryRun && Self.removesPreferences(runnable.filter { done.contains($0.id) }, home: context.home) {
            Shell.run("/usr/bin/killall", ["-u", NSUserName(), "cfprefsd"])
            report.log.append("cfprefsd relancé")
        }
        return report
    }

    static func removesPreferences(_ items: [ResultItem], home: URL) -> Bool {
        let prefs = home.appendingPathComponent("Library/Preferences").standardizedFileURL.path + "/"
        return items.contains { item in
            guard case .delete(let url, _, _) = item.action else { return false }
            return url.pathExtension == "plist" && url.standardizedFileURL.path.hasPrefix(prefs)
        }
    }

    public func appDependency(of item: ResultItem) -> AppDependency? {
        Self.bundlePath(of: item).map { AppDependency(name: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, bundlePath: $0) }
    }

    /// The app bundle an item belongs to: the bundle itself, or the prefix of a "<bundle>|<file>" id. Leftovers have none.
    static func bundlePath(of item: ResultItem) -> String? {
        if let bar = item.id.firstIndex(of: "|") { return String(item.id[..<bar]) }
        if case .delete(let url, _, _) = item.action, url.pathExtension == "app", item.id == url.path { return url.path }
        return nil
    }

    /// Library folders holding an app's data: what "Réinitialiser" removes.
    static let resetRoots = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State",
                             "Cookies", "HTTPStorages", "WebKit", "Logs", "Application Scripts"]

    /// "Réinitialiser": the app's data files in `group` (preferences, caches, containers…) only. Never the bundle,
    /// receipts, login items, Dock icon, launchd jobs, privileged helpers, plug-ins, command-line links, installers
    /// or crash reports.
    public static func resetSelection(_ group: ResultGroup) -> Set<String> {
        let plugins = Plugins.kinds.flatMap(\.dirs).map { "/Library/\($0)/" }
        return Set(group.allItems.map(\.id).filter { id in
            guard let bar = id.firstIndex(of: "|") else { return false }
            let path = String(id[id.index(after: bar)...])
            guard path.hasPrefix("/"), !path.contains("/Logs/DiagnosticReports/"), !plugins.contains(where: path.contains) else { return false }
            // Per-user cache and temporary folders under /var/folders are caches too.
            return resetRoots.contains { path.contains("/Library/\($0)/") } || path.contains("/var/folders/")
        })
    }
}

enum AppTerminator {
    /// Asks every process running from inside the bundle to quit and waits briefly. True when none is left.
    static func quit(bundlePath: String, timeout: TimeInterval = 8) async -> Bool {
        let prefix = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let pids: [pid_t] = NSWorkspace.shared.runningApplications.compactMap { app in
            let paths = [app.bundleURL, app.executableURL].compactMap { $0?.standardizedFileURL.path }
            guard paths.contains(where: { $0 == prefix || $0.hasPrefix(prefix + "/") }) else { return nil }
            app.terminate()
            return app.processIdentifier
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return pids.allSatisfy { kill($0, 0) != 0 }
    }
}
