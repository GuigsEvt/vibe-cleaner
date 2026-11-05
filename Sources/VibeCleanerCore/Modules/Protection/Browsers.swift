import AppKit
import Foundation

/// Browser privacy data: one row per category and profile.
/// Scans read copies of the databases; clearing happens only with the browser closed, either by SQL
/// (after a backup copy of the database goes to the Trash) or by moving the file to the Trash.
enum Browsers {
    /// Item action key: "browser:<bundle id>:<recipe>", recipe being "trash" or a `Recipe` raw value.
    static let keyPrefix = "browser:"

    /// SQL clearing a category.
    enum Recipe: String, CaseIterable {
        case safariHistory, chromeHistory, chromeDownloads, chromeSearches, chromeAutofill, chromePasswords, chromeCookies
        case firefoxHistory, firefoxDownloads, firefoxCookies, firefoxForms

        /// Firefox keeps a place while it is bookmarked or still has visits.
        static let firefoxOrphanPlaces = "DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL) AND id NOT IN (SELECT place_id FROM moz_historyvisits);"

        var sql: String {
            switch self {
            case .safariHistory: "DELETE FROM history_visits; DELETE FROM history_items;"
            case .chromeHistory: "DELETE FROM visits; DELETE FROM urls WHERE id NOT IN (SELECT url_id FROM keyword_search_terms WHERE url_id IS NOT NULL);"
            case .chromeDownloads: "DELETE FROM downloads_url_chains; DELETE FROM downloads;"
            case .chromeSearches: "DELETE FROM keyword_search_terms;"
            case .chromeAutofill: "DELETE FROM autofill;"
            case .chromePasswords: "DELETE FROM logins;"
            case .chromeCookies: "DELETE FROM cookies;"
            case .firefoxHistory: "DELETE FROM moz_historyvisits WHERE visit_type < 7; " + Self.firefoxOrphanPlaces
            case .firefoxDownloads: "DELETE FROM moz_historyvisits WHERE visit_type = 7; " + Self.firefoxOrphanPlaces
            case .firefoxCookies: "DELETE FROM moz_cookies;"
            case .firefoxForms: "DELETE FROM moz_formhistory;"
            }
        }

        /// Counts what the recipe would clear (run on a copy).
        var count: String {
            switch self {
            case .safariHistory: "SELECT COUNT(*) AS n FROM history_visits"
            case .chromeHistory: "SELECT COUNT(*) AS n FROM visits"
            case .chromeDownloads: "SELECT COUNT(*) AS n FROM downloads"
            case .chromeSearches: "SELECT COUNT(*) AS n FROM keyword_search_terms"
            case .chromeAutofill: "SELECT COUNT(*) AS n FROM autofill"
            case .chromePasswords: "SELECT COUNT(*) AS n FROM logins"
            case .chromeCookies: "SELECT COUNT(*) AS n FROM cookies"
            case .firefoxHistory: "SELECT COUNT(*) AS n FROM moz_historyvisits WHERE visit_type < 7"
            case .firefoxDownloads: "SELECT COUNT(*) AS n FROM moz_historyvisits WHERE visit_type = 7"
            case .firefoxCookies: "SELECT COUNT(*) AS n FROM moz_cookies"
            case .firefoxForms: "SELECT COUNT(*) AS n FROM moz_formhistory"
            }
        }
    }

    /// Chromium-based browsers sharing Chrome's profile layout, under ~/Library/Application Support.
    static let chromium: [(name: String, bundleID: String, folder: String)] = [
        ("Google Chrome", "com.google.Chrome", "Google/Chrome"),
        ("Google Chrome Beta", "com.google.Chrome.beta", "Google/Chrome Beta"),
        ("Google Chrome Dev", "com.google.Chrome.dev", "Google/Chrome Dev"),
        ("Google Chrome Canary", "com.google.Chrome.canary", "Google/Chrome Canary"),
        ("Opera", "com.operasoftware.Opera", "com.operasoftware.Opera"),
        ("Chromium", "org.chromium.Chromium", "Chromium"),
        ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
        ("Arc", "company.thebrowser.Browser", "Arc/User Data"),
    ]

    static func scan(context: ModuleContext, running: Set<String>) -> ResultGroup {
        var groups: [ResultGroup] = []
        groups += safari(context: context, running: running)
        for b in chromium { groups += chromeProfiles(b, context: context, running: running) }
        groups += firefox(context: context, running: running)
        return ResultGroup(id: "privacy.browsers", title: "Données de navigation",
                           subtitle: "Historique, cookies, téléchargements et sessions. Le navigateur doit être fermé pour les effacer.",
                           symbol: "globe", groups: groups, autoSelect: false).oneByOne()
    }

    static let signsOut = "Vous serez déconnecté des sites"
    static let irreversible = "Irréversible"

    // MARK: Rows

    struct Browser {
        let name: String
        let bundleID: String
        let running: Bool
    }

    /// A category cleared by SQL; nil when the database is absent or the category is empty. Irreversible: the
    /// backup copy left in the Trash cannot be put back from the app. `note` says what the user loses.
    static func sqlItem(_ b: Browser, _ title: String, _ db: URL, _ recipe: Recipe, symbol: String, synced: Bool = false,
                        note: String? = nil, context: ModuleContext) -> ResultItem? {
        guard FileManager.default.fileExists(atPath: db.path), !context.isExcluded(db),
              let n = SQLite.rows(db, recipe.count)?.first?["n"].flatMap(Int.init), n > 0 else { return nil }
        var detail = "\(n) entrée(s)"
        if let note { detail += " — \(note)" }
        if synced { detail += " — synchronisé avec un compte : les données reviendraient" }
        if b.running { detail += " — quittez \(b.name) pour effacer" }
        var item = ResultItem(id: "privacy.browser.\(recipe.rawValue).\(db.path)", name: title, detail: detail, url: db, symbol: symbol,
                              action: synced ? .none : .custom("\(keyPrefix)\(b.bundleID):\(recipe.rawValue)"), autoSelect: false)
        item.customIsIrreversible = true
        return item
    }

    /// A category cleared by moving files to the Trash; nil when none exist. `irreversible`: cookies and passwords,
    /// which the browser recreates at once, so putting the old file back is not a way out.
    static func fileItem(_ b: Browser, _ title: String, _ url: URL, symbol: String, note: String? = nil, irreversible: Bool = false,
                         context: ModuleContext) -> ResultItem? {
        guard FileManager.default.fileExists(atPath: url.path), !context.isExcluded(url) else { return nil }
        let size = FileSizer.size(of: url)
        var detail = FileSizer.format(size)
        if let note { detail += " — \(note)" }
        if b.running { detail += " — quittez \(b.name) pour effacer" }
        var item = ResultItem(id: "privacy.browser.file.\(url.path)", name: title, detail: detail, url: url, size: size, symbol: symbol,
                              action: .custom("\(keyPrefix)\(b.bundleID):trash"), autoSelect: false)
        item.customIsIrreversible = irreversible
        return item
    }

    static func group(_ id: String, _ title: String, _ items: [ResultItem?]) -> [ResultGroup] {
        let found = items.compactMap { $0 }
        return found.isEmpty ? [] : [ResultGroup(id: "privacy.browser.\(id)", title: title, symbol: "globe", items: found, autoSelect: false).oneByOne()]
    }

    // MARK: Safari

    static func safari(context: ModuleContext, running: Set<String>) -> [ResultGroup] {
        let b = Browser(name: "Safari", bundleID: "com.apple.Safari", running: running.contains("com.apple.Safari"))
        let lib = context.home.appendingPathComponent("Library/Safari")
        let container = context.home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library")
        var items: [ResultItem?] = [
            sqlItem(b, "Historique", lib.appendingPathComponent("History.db"), .safariHistory, symbol: "clock", context: context),
            fileItem(b, "Cookies", container.appendingPathComponent("Cookies/Cookies.binarycookies"), symbol: "birthday.cake",
                     note: signsOut, irreversible: true, context: context),
            fileItem(b, "Cookies (ancien emplacement)", context.home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
                     symbol: "birthday.cake", note: signsOut, irreversible: true, context: context),
            fileItem(b, "Historique des téléchargements", lib.appendingPathComponent("Downloads.plist"), symbol: "arrow.down.circle", context: context),
            fileItem(b, "Stockage local des sites", lib.appendingPathComponent("LocalStorage"), symbol: "internaldrive", note: signsOut, context: context),
            fileItem(b, "Données des sites", container.appendingPathComponent("WebKit/WebsiteData"), symbol: "internaldrive", note: signsOut,
                     context: context),
            fileItem(b, "Onglets de la dernière session", lib.appendingPathComponent("LastSession.plist"), symbol: "square.on.square", context: context),
            fileItem(b, "Saisie automatique", lib.appendingPathComponent("Form Values"), symbol: "character.cursor.ibeam", context: context),
        ]
        let profiles = lib.appendingPathComponent("Profiles")
        for p in (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [] {
            items.append(sqlItem(b, "Historique (profil \(p.lastPathComponent.prefix(8)))", p.appendingPathComponent("History.db"),
                                 .safariHistory, symbol: "clock", context: context))
        }
        return group("safari", "Safari", items)
    }

    // MARK: Chrome and Chromium

    static func chromeProfiles(_ info: (name: String, bundleID: String, folder: String), context: ModuleContext,
                               running: Set<String>) -> [ResultGroup] {
        let root = context.home.appendingPathComponent("Library/Application Support").appendingPathComponent(info.folder)
        let b = Browser(name: info.name, bundleID: info.bundleID, running: running.contains(info.bundleID))
        // Opera keeps its default profile in the root folder itself.
        let dirs = ([root] + ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []))
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Preferences").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return dirs.flatMap { dir -> [ResultGroup] in
            let prefs = (try? Data(contentsOf: dir.appendingPathComponent("Preferences")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let synced = isSynced(prefs)
            let profileName = ((prefs["profile"] as? [String: Any])?["name"] as? String) ?? dir.lastPathComponent
            let cookies = [dir.appendingPathComponent("Network/Cookies"), dir.appendingPathComponent("Cookies")]
                .first { FileManager.default.fileExists(atPath: $0.path) } ?? dir.appendingPathComponent("Cookies")
            let history = dir.appendingPathComponent("History"), webData = dir.appendingPathComponent("Web Data")
            let title = dirs.count > 1 ? "\(info.name) — \(profileName)" : info.name
            return group("\(info.bundleID).\(dir.lastPathComponent)", title, [
                sqlItem(b, "Historique", history, .chromeHistory, symbol: "clock", synced: synced, context: context),
                sqlItem(b, "Historique des téléchargements", history, .chromeDownloads, symbol: "arrow.down.circle", context: context),
                sqlItem(b, "Recherches", history, .chromeSearches, symbol: "magnifyingglass", synced: synced, context: context),
                sqlItem(b, "Cookies", cookies, .chromeCookies, symbol: "birthday.cake", note: signsOut, context: context),
                sqlItem(b, "Saisie automatique", webData, .chromeAutofill, symbol: "character.cursor.ibeam", synced: synced, context: context),
                sqlItem(b, "Mots de passe enregistrés", dir.appendingPathComponent("Login Data"), .chromePasswords, symbol: "key",
                        synced: synced, note: irreversible, context: context),
                sqlItem(b, "Mots de passe du compte", dir.appendingPathComponent("Login Data For Account"), .chromePasswords, symbol: "key",
                        synced: synced, note: irreversible, context: context),
                fileItem(b, "Onglets de la dernière session", dir.appendingPathComponent("Sessions"), symbol: "square.on.square", context: context),
            ])
        }
    }

    /// A profile signed in with sync turned on would get synced data back right after clearing.
    static func isSynced(_ prefs: [String: Any]) -> Bool {
        let sync = prefs["sync"] as? [String: Any] ?? [:]
        let signedIn = !(prefs["account_info"] as? [Any] ?? []).isEmpty
        return signedIn && (sync["has_setup_completed"] as? Bool ?? false)
    }

    // MARK: Firefox

    /// Profile folders listed by `profiles.ini` (`Path=`, relative unless `IsRelative=0`).
    static func firefoxProfiles(ini: String, base: URL) -> [URL] {
        var out: [URL] = []
        var path: String?, relative = true
        func flush() {
            if let path, !path.isEmpty { out.append(relative ? base.appendingPathComponent(path) : URL(fileURLWithPath: path)) }
            path = nil; relative = true
        }
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { flush() }
            else if line.hasPrefix("Path=") { path = String(line.dropFirst(5)) }
            else if line.hasPrefix("IsRelative=") { relative = line.dropFirst(11) != "0" }
        }
        flush()
        return out
    }

    static func firefox(context: ModuleContext, running: Set<String>) -> [ResultGroup] {
        let base = context.home.appendingPathComponent("Library/Application Support/Firefox")
        let root = base.appendingPathComponent("Profiles")
        let b = Browser(name: "Firefox", bundleID: "org.mozilla.firefox", running: running.contains("org.mozilla.firefox"))
        let ini = (try? String(contentsOf: base.appendingPathComponent("profiles.ini"), encoding: .utf8)).map { firefoxProfiles(ini: $0, base: base) } ?? []
        var seen = Set<String>()
        let dirs = (((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []) + ini)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted && FileManager.default.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path) }
        return dirs.flatMap { dir in
            let places = dir.appendingPathComponent("places.sqlite")
            let title = dirs.count > 1 ? "Firefox — \(dir.lastPathComponent)" : "Firefox"
            return group("firefox.\(dir.lastPathComponent)", title, [
                sqlItem(b, "Historique", places, .firefoxHistory, symbol: "clock", context: context),
                sqlItem(b, "Historique des téléchargements", places, .firefoxDownloads, symbol: "arrow.down.circle", context: context),
                sqlItem(b, "Cookies", dir.appendingPathComponent("cookies.sqlite"), .firefoxCookies, symbol: "birthday.cake", note: signsOut,
                        context: context),
                sqlItem(b, "Saisie automatique", dir.appendingPathComponent("formhistory.sqlite"), .firefoxForms,
                        symbol: "character.cursor.ibeam", context: context),
                fileItem(b, "Mots de passe enregistrés", dir.appendingPathComponent("logins.json"), symbol: "key", note: irreversible,
                         irreversible: true, context: context),
                fileItem(b, "Onglets de la dernière session", dir.appendingPathComponent("sessionstore-backups"),
                         symbol: "square.on.square", context: context),
                fileItem(b, "Session enregistrée", dir.appendingPathComponent("sessionstore.jsonlz4"), symbol: "square.on.square", context: context),
                fileItem(b, "Session enregistrée (ancien format)", dir.appendingPathComponent("sessionstore.js"), symbol: "square.on.square", context: context),
                fileItem(b, "Sauvegarde de session", dir.appendingPathComponent("sessionstore.bak"), symbol: "square.on.square", context: context),
                fileItem(b, "Session (session.db)", dir.appendingPathComponent("session.db"), symbol: "square.on.square", context: context),
            ])
        }
    }

    // MARK: Execute

    static func dependency(key: String) -> AppDependency? {
        guard key.hasPrefix(keyPrefix), let id = key.dropFirst(keyPrefix.count).split(separator: ":").first.map(String.init) else { return nil }
        let names = Dictionary(uniqueKeysWithValues: chromium.map { ($0.bundleID, $0.name) })
            .merging(["com.apple.Safari": "Safari", "org.mozilla.firefox": "Firefox"]) { a, _ in a }
        return AppDependency(name: names[id] ?? id, bundleID: id)
    }

    /// Clears one category. Refuses while the browser runs: it would write the data back or corrupt its database.
    static func clear(_ item: ResultItem, key: String, remover: SafeRemover,
                      isRunning: (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
                      backUp: (URL) throws -> Void = backUpToTrash) throws {
        let parts = key.dropFirst(keyPrefix.count).split(separator: ":", maxSplits: 1).map(String.init)
        guard key.hasPrefix(keyPrefix), parts.count == 2, let url = item.url else { throw RemovalError.failed(item.name, "action inconnue \(key)") }
        if isRunning(parts[0]) { throw RemovalError.failed(item.name, "quittez le navigateur puis réessayez") }
        try remover.check(url)
        if parts[1] == "trash" {
            if let f = remover.remove([url], mode: .trash).failures.first { throw RemovalError.failed(url.path, f.1) }
            return
        }
        guard let recipe = Recipe(rawValue: parts[1]) else { throw RemovalError.failed(item.name, "action inconnue \(key)") }
        if remover.dryRun { return }
        try backUp(url)
        try SQLite.execute(url, recipe.sql)
    }

    /// Copies a database (and its WAL) into the Trash before it is modified, so the user can still go back.
    static func backUpToTrash(_ db: URL) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vc-backup-\(UUID().uuidString)")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let backup = dir.appendingPathComponent("\(db.deletingLastPathComponent().lastPathComponent) \(db.lastPathComponent) \(stamp)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for suffix in ["", "-wal"] where fm.fileExists(atPath: db.path + suffix) {
            try fm.copyItem(atPath: db.path + suffix, toPath: backup.appendingPathComponent(db.lastPathComponent + suffix).path)
        }
        try fm.trashItem(at: backup, resultingItemURL: nil)
    }
}
