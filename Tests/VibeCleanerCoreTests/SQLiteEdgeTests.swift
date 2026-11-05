import Foundation
import SQLite3
import Testing
@testable import VibeCleanerCore

/// SQLite helpers and browser clearing, on databases created by the test in a temporary folder.
/// `Browsers.clear` always gets an injected backup closure: the real one writes into the user's Trash.
@Suite struct SQLiteEdgeTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("vc-sql-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    @discardableResult
    func makeDB(_ name: String, wal: Bool = false, _ sql: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        #expect(sqlite3_exec(h, (wal ? "PRAGMA journal_mode=WAL; " : "") + sql, nil, nil, nil) == SQLITE_OK)
        return url
    }

    func count(_ db: URL, _ table: String) -> Int? {
        SQLite.rows(db, "SELECT COUNT(*) AS n FROM \(table)")?.first?["n"].flatMap(Int.init)
    }

    // MARK: rows

    @Test func rowsOnMissingInvalidOrNonDatabaseFilesIsNil() throws {
        #expect(SQLite.rows(tmp.appendingPathComponent("absent.db"), "SELECT 1") == nil)
        let db = try makeDB("ok.db", "CREATE TABLE t (a TEXT);")
        #expect(SQLite.rows(db, "SELECT nope FROM t") == nil)
        #expect(SQLite.rows(db, "") == []) // empty statement: nothing to read, not an error
        let text = tmp.appendingPathComponent("text.db")
        try Data("not a database at all, just some text".utf8).write(to: text)
        #expect(SQLite.rows(text, "SELECT 1") == nil)
        #expect(SQLite.rows(tmp, "SELECT 1") == nil) // a folder
    }

    @Test func rowsLeaveOutNullsAndReturnEmptyForNoRows() throws {
        let db = try makeDB("n.db", "CREATE TABLE t (a TEXT, b INTEGER); INSERT INTO t VALUES (NULL, 3), ('é''x', NULL);")
        let rows = try #require(SQLite.rows(db, "SELECT a, b FROM t ORDER BY rowid"))
        #expect(rows == [["b": "3"], ["a": "é'x"]])
        #expect(SQLite.rows(db, "SELECT a FROM t WHERE 0") == [])
    }

    /// Browsers keep recent writes in the WAL: the copy must include it, and the original must stay untouched.
    @Test func rowsSeeTheWALAndNeverTouchTheOriginal() throws {
        let url = tmp.appendingPathComponent("dir with space/Histo'ry")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        #expect(sqlite3_exec(h, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t (a); INSERT INTO t VALUES (1), (2);", nil, nil, nil) == SQLITE_OK)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        #expect(fm.fileExists(atPath: wal.path))
        let before = try (Data(contentsOf: url), Data(contentsOf: wal))
        let mtime = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        #expect(count(url, "t") == 2)

        #expect(try Data(contentsOf: url) == before.0)
        #expect(try Data(contentsOf: wal) == before.1)
        #expect(try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == mtime)
    }

    // MARK: execute

    @Test func executeCommitsOrRollsBackAsOneTransaction() throws {
        let db = try makeDB("tx.db", "CREATE TABLE a (x); CREATE TABLE b (x); INSERT INTO a VALUES (1), (2); INSERT INTO b VALUES (1);")
        #expect(throws: RemovalError.self) { try SQLite.execute(db, "DELETE FROM a; DELETE FROM missing_table;") }
        #expect(count(db, "a") == 2) // first statement rolled back
        try SQLite.execute(db, "DELETE FROM a; DELETE FROM b;")
        #expect(count(db, "a") == 0)
        #expect(count(db, "b") == 0)
    }

    @Test func executeWithoutTrailingSemicolonFailsCleanly() throws {
        let db = try makeDB("semi.db", "CREATE TABLE a (x); INSERT INTO a VALUES (1);")
        // "BEGIN IMMEDIATE; DELETE FROM a COMMIT;" is not valid SQL: refused, nothing changed, no open transaction left.
        #expect(throws: RemovalError.self) { try SQLite.execute(db, "DELETE FROM a") }
        #expect(count(db, "a") == 1)
        try SQLite.execute(db, "DELETE FROM a;")
        #expect(count(db, "a") == 0)
    }

    @Test func executeNeverCreatesAMissingDatabase() {
        let absent = tmp.appendingPathComponent("absent.db")
        #expect(throws: RemovalError.self) { try SQLite.execute(absent, "DELETE FROM t;") }
        #expect(!fm.fileExists(atPath: absent.path))
    }

    @Test func executeOnANonDatabaseFileThrowsAndKeepsIt() throws {
        let f = tmp.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: f)
        #expect(throws: RemovalError.self) { try SQLite.execute(f, "DELETE FROM t;") }
        #expect(try Data(contentsOf: f) == Data("hello".utf8))
    }

    /// Another process holds the write lock (the browser is still writing): the busy timeout expires, nothing changes.
    @Test func executeGivesUpWhenTheDatabaseIsLocked() throws {
        let db = try makeDB("locked.db", wal: true, "CREATE TABLE t (x); INSERT INTO t VALUES (1);")
        var other: OpaquePointer?
        #expect(sqlite3_open(db.path, &other) == SQLITE_OK)
        defer { sqlite3_close(other) }
        #expect(sqlite3_exec(other, "BEGIN IMMEDIATE; INSERT INTO t VALUES (2);", nil, nil, nil) == SQLITE_OK)
        #expect(throws: RemovalError.self) { try SQLite.execute(db, "DELETE FROM t;") }
        #expect(sqlite3_exec(other, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
        #expect(count(db, "t") == 1)
    }

    // MARK: Browsers.clear

    func historyItem(_ db: URL, key: String = "browser:com.google.Chrome:chromeHistory") -> ResultItem {
        ResultItem(id: "h", name: "Historique", url: db, action: .custom(key), autoSelect: false)
    }

    func chromeHistory() throws -> URL {
        try makeDB("Chrome/Default/History", wal: true, """
            CREATE TABLE urls (id INTEGER PRIMARY KEY); CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER);
            CREATE TABLE keyword_search_terms (url_id INTEGER); INSERT INTO urls VALUES (1); INSERT INTO visits VALUES (1, 1);
            """)
    }

    /// The module skips `.custom` actions in dry-run, but `clear` itself receives a dry-run remover and
    /// must honour it like every other removal path (the "trash" recipe already does).
    @Test func clearHonoursDryRun() throws {
        let db = try chromeHistory()
        var backups = 0
        try Browsers.clear(historyItem(db), key: "browser:com.google.Chrome:chromeHistory",
                           remover: SafeRemover(dryRun: true, home: tmp.path), isRunning: { _ in false }) { _ in backups += 1 }
        #expect(count(db, "visits") == 1)
        #expect(backups == 0)
    }

    @Test func clearRefusesExcludedDatabasesBeforeBackingUp() throws {
        let db = try chromeHistory()
        var backups = 0
        #expect(throws: RemovalError.self) {
            try Browsers.clear(historyItem(db), key: "browser:com.google.Chrome:chromeHistory",
                               remover: SafeRemover(userExclusions: [db.deletingLastPathComponent().path], home: tmp.path),
                               isRunning: { _ in false }) { _ in backups += 1 }
        }
        #expect(backups == 0)
        #expect(count(db, "visits") == 1)
    }

    @Test func clearDoesNotTouchTheDatabaseWhenTheBackupFails() throws {
        struct NoTrash: Error {}
        let db = try chromeHistory()
        #expect(throws: NoTrash.self) {
            try Browsers.clear(historyItem(db), key: "browser:com.google.Chrome:chromeHistory",
                               remover: SafeRemover(home: tmp.path), isRunning: { _ in false }) { _ in throw NoTrash() }
        }
        #expect(count(db, "visits") == 1)
    }

    @Test(arguments: ["browser:", "browser:com.google.Chrome", "browser:com.google.Chrome:dropEverything", "other:com.x:chromeHistory"])
    func clearRefusesMalformedKeys(_ key: String) throws {
        let db = try chromeHistory()
        var backups = 0
        #expect(throws: (any Error).self) {
            try Browsers.clear(historyItem(db, key: key), key: key, remover: SafeRemover(home: tmp.path), isRunning: { _ in false }) { _ in backups += 1 }
        }
        #expect(backups == 0)
        #expect(count(db, "visits") == 1)
    }

    @Test func clearNeedsAURL() {
        let item = ResultItem(id: "x", name: "x", action: .custom("browser:com.google.Chrome:chromeHistory"))
        #expect(throws: RemovalError.self) {
            try Browsers.clear(item, key: "browser:com.google.Chrome:chromeHistory", remover: SafeRemover(dryRun: true), isRunning: { _ in false }) { _ in }
        }
    }

    @Test func trashRecipeInDryRunKeepsTheFile() throws {
        let f = tmp.appendingPathComponent("LastSession.plist")
        try Data(count: 10).write(to: f)
        let item = ResultItem(id: "s", name: "s", url: f, action: .custom("browser:com.apple.Safari:trash"))
        try Browsers.clear(item, key: "browser:com.apple.Safari:trash", remover: SafeRemover(dryRun: true, home: tmp.path),
                           isRunning: { _ in false }) { _ in Issue.record("no backup for trash rows") }
        #expect(fm.fileExists(atPath: f.path))
    }

    @Test func everyRecipeIsValidSQLOnItsSchema() throws {
        // Minimal schemas holding the tables each recipe names.
        let schema = """
            CREATE TABLE history_visits (x); CREATE TABLE history_items (x); CREATE TABLE visits (x); CREATE TABLE urls (id);
            CREATE TABLE keyword_search_terms (url_id); CREATE TABLE downloads_url_chains (x); CREATE TABLE downloads (x);
            CREATE TABLE autofill (x); CREATE TABLE logins (x); CREATE TABLE cookies (x);
            CREATE TABLE moz_places (id); CREATE TABLE moz_bookmarks (fk); CREATE TABLE moz_historyvisits (place_id, visit_type);
            CREATE TABLE moz_cookies (x); CREATE TABLE moz_formhistory (x);
            """
        for recipe in Browsers.Recipe.allCases {
            let db = try makeDB("\(recipe.rawValue).db", schema)
            #expect(SQLite.rows(db, recipe.count)?.first?["n"] == "0", "\(recipe)")
            do { try SQLite.execute(db, recipe.sql) } catch { Issue.record("\(recipe): \(error)") }
        }
    }

    @Test func chromeHistoryKeepsURLsWhenASearchTermHasANullURL() throws {
        // NOT IN over a set holding NULL is never true: one NULL url_id would keep every url.
        let db = try makeDB("nullsearch.db", """
            CREATE TABLE urls (id INTEGER PRIMARY KEY); CREATE TABLE visits (x); CREATE TABLE keyword_search_terms (url_id);
            INSERT INTO urls VALUES (1), (2); INSERT INTO keyword_search_terms VALUES (NULL), (2);
            """)
        try SQLite.execute(db, Browsers.Recipe.chromeHistory.sql)
        #expect(SQLite.rows(db, "SELECT id FROM urls")?.compactMap { $0["id"] } == ["2"])
    }

    // MARK: Scan side

    @Test func profilesWithoutTheirMarkerFileAreIgnored() throws {
        try makeDB("home/Library/Application Support/Google/Chrome/NoPrefs/History", "CREATE TABLE visits (x); INSERT INTO visits VALUES (1);")
        try makeDB("home/Library/Application Support/Firefox/Profiles/p/cookies.sqlite", "CREATE TABLE moz_cookies (x); INSERT INTO moz_cookies VALUES (1);")
        #expect(Browsers.scan(context: ModuleContext(home: tmp.appendingPathComponent("home")), running: []).allItems.isEmpty)
    }

    @Test func emptyOrExcludedCategoriesAreNotListed() throws {
        let home = tmp.appendingPathComponent("home")
        let places = try makeDB("home/Library/Application Support/Firefox/Profiles/p/places.sqlite", """
            CREATE TABLE moz_places (id); CREATE TABLE moz_bookmarks (fk); CREATE TABLE moz_historyvisits (place_id, visit_type);
            INSERT INTO moz_historyvisits VALUES (1, 1);
            """)
        let all = Browsers.scan(context: ModuleContext(home: home), running: []).allItems.map(\.name)
        #expect(all == ["Historique"]) // downloads empty → no row
        #expect(Browsers.scan(context: ModuleContext(exclusions: [places.path], home: home), running: []).allItems.isEmpty)
    }

    @Test func syncNeedsBothAccountAndCompletedSetup() {
        #expect(!Browsers.isSynced([:]))
        #expect(!Browsers.isSynced(["account_info": [] as [Any], "sync": ["has_setup_completed": true]]))
        #expect(!Browsers.isSynced(["account_info": [["e": "a"]], "sync": ["has_setup_completed": false]]))
        #expect(!Browsers.isSynced(["account_info": "garbage", "sync": "garbage"]))
        #expect(Browsers.isSynced(["account_info": [["e": "a"]], "sync": ["has_setup_completed": true]]))
    }

    @Test func dependencyOfKeys() {
        #expect(Browsers.dependency(key: "browser:com.brave.Browser:chromeCookies")?.name == "Brave")
        #expect(Browsers.dependency(key: "browser:com.unknown:trash")?.name == "com.unknown")
        #expect(Browsers.dependency(key: "quarantine-file") == nil)
        #expect(Browsers.dependency(key: "browser:") == nil)
    }
}
