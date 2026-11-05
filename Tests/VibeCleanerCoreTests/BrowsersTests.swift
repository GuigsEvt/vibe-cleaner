import Foundation
import SQLite3
import Testing
@testable import VibeCleanerCore

@Suite struct BrowsersTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appendingPathComponent("vc-browsers-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func db(_ url: URL, _ sql: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        #expect(sqlite3_exec(h, "PRAGMA journal_mode=WAL; " + sql, nil, nil, nil) == SQLITE_OK)
    }

    func count(_ url: URL, _ table: String) -> Int? {
        SQLite.rows(url, "SELECT COUNT(*) AS n FROM \(table)")?.first?["n"].flatMap(Int.init)
    }

    func chromeProfile(synced: Bool) throws -> URL {
        let dir = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try db(dir.appendingPathComponent("History"), """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT); CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER);
            CREATE TABLE keyword_search_terms (keyword_id INTEGER, url_id INTEGER, term TEXT);
            CREATE TABLE downloads (id INTEGER PRIMARY KEY); CREATE TABLE downloads_url_chains (id INTEGER, url TEXT);
            INSERT INTO urls VALUES (1, 'a'), (2, 'b'); INSERT INTO visits VALUES (1, 1), (2, 1), (3, 2);
            INSERT INTO keyword_search_terms VALUES (1, 2, 'chat'); INSERT INTO downloads VALUES (1);
            """)
        try db(dir.appendingPathComponent("Network/Cookies"), "CREATE TABLE cookies (host_key TEXT); INSERT INTO cookies VALUES ('x.com');")
        let prefs: [String: Any] = synced ? ["account_info": [["email": "a@b.c"]], "sync": ["has_setup_completed": true]] : ["profile": ["name": "Perso"]]
        try JSONSerialization.data(withJSONObject: prefs).write(to: dir.appendingPathComponent("Preferences"))
        return dir
    }

    @Test func scansChromeProfileCategories() throws {
        _ = try chromeProfile(synced: false)
        let g = Browsers.scan(context: ModuleContext(home: home), running: ["com.google.Chrome"])
        let chrome = try #require(g.groups.first)
        #expect(chrome.title == "Google Chrome")
        let byName = Dictionary(uniqueKeysWithValues: chrome.items.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Historique", "Historique des téléchargements", "Recherches", "Cookies"])
        #expect(byName["Historique"]?.detail == "3 entrée(s) — quittez Google Chrome pour effacer")
        #expect(byName["Cookies"]?.url?.path.hasSuffix("Network/Cookies") == true)
        #expect(byName["Historique"]?.action == .custom("browser:com.google.Chrome:chromeHistory"))
        #expect(g.defaultSelection.isEmpty)
    }

    @Test func syncedChromeDataIsNotRemovable() throws {
        _ = try chromeProfile(synced: true)
        let items = Browsers.scan(context: ModuleContext(home: home), running: []).allItems
        #expect(items.first { $0.name == "Historique" }?.action == ItemAction.none)
        #expect(items.first { $0.name == "Cookies" }?.action != ItemAction.none)
    }

    @Test func clearsChromeHistoryAfterBackup() throws {
        let dir = try chromeProfile(synced: false)
        let history = dir.appendingPathComponent("History")
        let item = try #require(Browsers.scan(context: ModuleContext(home: home), running: []).allItems.first { $0.name == "Historique" })
        guard case .custom(let key) = item.action else { Issue.record("action"); return }
        var backedUp: [URL] = []
        try Browsers.clear(item, key: key, remover: SafeRemover(home: home.path), isRunning: { _ in false }) { backedUp.append($0) }
        #expect(backedUp.map(\.lastPathComponent) == ["History"])
        #expect(count(history, "visits") == 0)
        #expect(count(history, "urls") == 1) // kept: referenced by a search term
        #expect(count(history, "downloads") == 1)
    }

    @Test func refusesWhileBrowserRuns() throws {
        let dir = try chromeProfile(synced: false)
        let item = try #require(Browsers.scan(context: ModuleContext(home: home), running: []).allItems.first { $0.name == "Cookies" })
        guard case .custom(let key) = item.action else { Issue.record("action"); return }
        #expect(throws: RemovalError.self) {
            try Browsers.clear(item, key: key, remover: SafeRemover(home: home.path), isRunning: { _ in true }) { _ in }
        }
        #expect(count(dir.appendingPathComponent("Network/Cookies"), "cookies") == 1)
    }

    @Test func firefoxHistoryKeepsBookmarkedPlaces() throws {
        let places = home.appendingPathComponent("Library/Application Support/Firefox/Profiles/abc.default/places.sqlite")
        try db(places, """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY); CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, fk INTEGER);
            CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_type INTEGER);
            INSERT INTO moz_places VALUES (1), (2), (3); INSERT INTO moz_bookmarks VALUES (1, 1);
            INSERT INTO moz_historyvisits VALUES (1, 1, 1), (2, 2, 1), (3, 3, 7);
            """)
        let items = Browsers.scan(context: ModuleContext(home: home), running: []).allItems
        let history = try #require(items.first { $0.name == "Historique" })
        #expect(history.detail == "2 entrée(s)")
        #expect(items.first { $0.name == "Historique des téléchargements" }?.detail == "1 entrée(s)")
        guard case .custom(let key) = history.action else { Issue.record("action"); return }
        try Browsers.clear(history, key: key, remover: SafeRemover(home: home.path), isRunning: { _ in false }) { _ in }
        #expect(count(places, "moz_historyvisits") == 1)
        #expect(SQLite.rows(places, "SELECT id FROM moz_places ORDER BY id")?.compactMap { $0["id"] } == ["1", "3"])
    }

    @Test func safariFilesAreTrashRows() throws {
        let lib = home.appendingPathComponent("Library/Safari")
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data(count: 100).write(to: lib.appendingPathComponent("LastSession.plist"))
        let g = Browsers.scan(context: ModuleContext(home: home), running: [])
        let row = try #require(g.allItems.first)
        #expect(row.name == "Onglets de la dernière session")
        #expect(row.action == .custom("browser:com.apple.Safari:trash"))
        #expect(row.size > 0)
    }
}
