import Foundation
import SQLite3
import Testing
@testable import VibeCleanerCore

@Suite struct PrivacyTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("vc-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeTCC(_ rows: [(String, String, Int, Int)], at path: URL? = nil) throws {
        let db = path ?? Privacy.tccDatabase(home: home)
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        #expect(sqlite3_open(db.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        var sql = "PRAGMA journal_mode=WAL; CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER, last_modified INTEGER);"
        for (s, c, t, a) in rows { sql += "INSERT INTO access VALUES ('\(s)', '\(c)', \(t), \(a), 0);" }
        #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func listsGrantedPermissionsByService() throws {
        try makeTCC([("kTCCServiceCamera", "com.example.zoom", 0, 2),
                     ("kTCCServiceCamera", "com.example.denied", 0, 0),
                     ("kTCCServiceMicrophone", "com.example.zoom", 0, 2),
                     ("kTCCServicePhotos", "com.example.limited", 0, 3),
                     ("kTCCServiceCamera", "/usr/local/bin/tool", 1, 2)])
        let g = Privacy.permissions(context: ModuleContext(home: home)) { $0 == "com.example.zoom" ? "Zoom" : nil }
        #expect(g.groups.map(\.title) == ["Caméra", "Micro", "Photos"])
        let camera = try #require(g.groups.first)
        #expect(camera.items.map(\.name) == ["Zoom"])
        #expect(camera.items[0].action == .command(executable: "/usr/bin/tccutil", arguments: ["reset", "Camera", "com.example.zoom"], admin: false))
        #expect(g.groups[2].items[0].detail?.hasPrefix("Accès limité") == true)
        #expect(g.defaultSelection.isEmpty)
    }

    @Test func unreadableTCCGivesEmptyGroup() {
        #expect(Privacy.permissions(context: ModuleContext(home: home)).isEmpty)
    }

    @Test func addsSystemGrantsAndCameraMicrophoneTile() throws {
        try makeTCC([("kTCCServiceCamera", "com.example.zoom", 0, 2)])
        let system = home.appendingPathComponent("system/TCC.db")
        try makeTCC([("kTCCServiceScreenCapture", "com.example.zoom", 0, 2), ("kTCCServiceMicrophone", "com.example.rec", 0, 2)], at: system)
        let g = Privacy.permissions(context: ModuleContext(home: home), systemDB: system) { _ in nil }
        let screen = try #require(g.groups.first { $0.id == "privacy.tcc.ScreenCapture" }?.items.first)
        #expect(screen.action == .command(executable: "/usr/bin/tccutil", arguments: ["reset", "ScreenCapture", "com.example.zoom"], admin: true))
        let tile = Privacy.cameraMicrophone(g)
        #expect(tile.title == "Caméra et micro")
        #expect(tile.groups.map(\.title) == ["Caméra", "Micro"])
        #expect(tile.subtitle?.hasPrefix("2 app(s)") == true)
        // Same ids as the permission rows (lot C): one tick, one tccutil reset.
        #expect(Set(tile.allItems.map(\.id)).isSubset(of: g.allItems.map(\.id)))
        #expect(tile.defaultSelection.isEmpty)
        #expect(Privacy.cameraMicrophone(Privacy.permissions(context: ModuleContext(home: home.appendingPathComponent("none")))).isEmpty)
    }

    @Test func readsRecentItemsLists() throws {
        let root = Privacy.sharedFileLists(home: home)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments"),
                                                withIntermediateDirectories: true)
        let doc = home.appendingPathComponent("Rapport.pdf")
        try Data("x".utf8).write(to: doc)
        let list: NSDictionary = ["items": [["Bookmark": try doc.bookmarkData()], ["Name": "Serveur"]], "properties": NSDictionary()]
        let data = try NSKeyedArchiver.archivedData(withRootObject: list, requiringSecureCoding: true)
        try data.write(to: root.appendingPathComponent("com.apple.LSSharedFileList.RecentDocuments.sfl3"))
        try data.write(to: root.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments/com.example.app.sfl3"))
        let empty = try NSKeyedArchiver.archivedData(withRootObject: ["items": NSArray()] as NSDictionary, requiringSecureCoding: true)
        try empty.write(to: root.appendingPathComponent("com.apple.LSSharedFileList.RecentServers.sfl3"))

        let g = Privacy.recentItems(context: ModuleContext(home: home))
        #expect(g.items.count == 2)
        let docs = try #require(g.items.first { $0.name == "Documents récents" })
        #expect(docs.detail == "2 élément(s) : Rapport.pdf, Serveur")
        #expect(docs.action == .custom(Privacy.removeRecentList))
        #expect(g.items.contains { $0.name == "Documents récents de com.example.app" })
        #expect(g.defaultSelection.isEmpty)
    }

    @Test func dryRunLeavesRecentListsInPlace() async throws {
        let root = Privacy.sharedFileLists(home: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("com.apple.LSSharedFileList.RecentApplications.sfl3")
        try NSKeyedArchiver.archivedData(withRootObject: ["items": [["Name": "Safari"]]] as NSDictionary, requiringSecureCoding: true).write(to: file)
        let item = try #require(Privacy.recentItems(context: ModuleContext(home: home)).items.first)
        let r = await ProtectionModule().execute([item], context: ModuleContext(dryRun: true, home: home))
        #expect(r.processed == [item.id])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
