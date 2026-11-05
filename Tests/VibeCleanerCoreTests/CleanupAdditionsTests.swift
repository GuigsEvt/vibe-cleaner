import Foundation
import SQLite3
import Testing
@testable import VibeCleanerCore

/// Cleanup additions: Dropbox / App Store caches, coresymbolicationd, broken startup items, simulator runtimes,
/// Mail account filter, Mail and iCloud trashes. Everything lives in a temporary fake home.
@Suite struct CleanupAdditionsTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("vc-cleanup2-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: Junk.realPath(dir.path))
    }

    var scope: JunkScope { JunkScope(context: ModuleContext(home: home), system: false, running: []) }

    @discardableResult
    func file(_ path: String, bytes: Int = 5000, data: Data? = nil) throws -> URL {
        let url = home.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? Data(repeating: 0x41, count: bytes)).write(to: url)
        return url
    }

    func plist(_ path: String, _ dict: [String: Any]) throws {
        try file(path, data: try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0))
    }

    func scan() async -> [ResultGroup] {
        await CleanupModule(scansSystemLocations: false).scan(context: ModuleContext(home: home)) { _, _ in }.map { $0.pruned() }
    }

    // MARK: Caches

    @Test func findsDropboxCache() async throws {
        let dropbox = home.appendingPathComponent("Dropbox")
        try file(".dropbox/info.json", data: try JSONSerialization.data(withJSONObject: ["personal": ["path": dropbox.path]]))
        try file("Dropbox/.dropbox.cache/2026-10-01/blob")
        try file("Dropbox/.dropbox.cache/empty", bytes: 0)
        try file("Dropbox/Documents/keep.txt")
        // Lot B: a cache written in the last 10 minutes is not selected.
        for p in ["Dropbox/.dropbox.cache/2026-10-01", "Dropbox/.dropbox.cache/2026-10-01/blob"] {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: home.appendingPathComponent(p).path)
        }
        let caches = try #require(await scan().first { $0.id == "cleanup.system.userCaches" })
        let names = caches.allItems.map(\.name)
        #expect(names == ["Dropbox — 2026-10-01"])
        #expect(caches.defaultSelection.count == 1)
    }

    @Test func appStoreDownloadsSkipRecentFolders() throws {
        let root = home.appendingPathComponent("darwin/com.apple.appstore")
        let old = try file("darwin/com.apple.appstore/123456789/app.pkg").deletingLastPathComponent()
        try file("darwin/com.apple.appstore/987654321/app.pkg")
        try file("darwin/com.apple.appstore/com.apple.AppStore/x")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: old.path)
        let items = CacheScanner.appStoreDownloads([root], scope)
        #expect(Set(items.map(\.url?.lastPathComponent)) == ["123456789", "987654321"])
        #expect(items.allSatisfy { !$0.autoSelect }) // V1-B7: never selected
    }

    // MARK: Broken startup items

    @Test func missingProgramNeedsReadableParent() throws {
        #expect(SystemJunkScanner.isMissing("/nonexistent/vc-agent"))
        #expect(!SystemJunkScanner.isMissing("/bin/ls"))
        let locked = home.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        // Cannot be checked without privileges: never reported.
        #expect(!SystemJunkScanner.isMissing(locked.appendingPathComponent("tool").path))
    }

    @Test func brokenLoginItemsAreListed() {
        let gone = home.appendingPathComponent("Gone.app")
        let items = SystemJunkScanner.brokenLoginItems([.init(name: "Gone", url: gone), .init(name: "Ls", url: URL(fileURLWithPath: "/bin/ls")),
                                                        .init(name: "Ext", url: URL(fileURLWithPath: "/Volumes/NoDisk/Ext.app")),
                                                        .init(name: "Alias", url: nil)], scope)
        #expect(items.map(\.name) == ["Gone", "Ext", "Alias"])
        #expect(items.map(\.autoSelect) == [true, false, false])
        #expect(items.allSatisfy { $0.action == .custom(PerformanceModule.Key.removeLoginItem) })
        #expect(items[0].id == "cleanup.loginitem.\(gone.path)")
        let excluded = JunkScope(context: ModuleContext(exclusions: [gone.path], home: home), system: false, running: [])
        #expect(SystemJunkScanner.brokenLoginItems([.init(name: "Gone", url: gone)], excluded).isEmpty)
    }

    @Test func cleanupRevalidatesAdminCommandsAndRunsNothingInDryRun() async throws {
        let ctx = ModuleContext(dryRun: true, home: home)
        let bad = ResultItem(id: "bad", name: "bad", url: URL(fileURLWithPath: "/System/Library/x.plist"),
                             action: .command(executable: "/bin/sh", arguments: ["-c", "exit 1"], admin: true))
        let login = ResultItem(id: "login", name: "Gone", url: home.appendingPathComponent("Gone.app"),
                               action: .custom(PerformanceModule.Key.removeLoginItem))
        let report = await CleanupModule(scansSystemLocations: false).execute([bad, login], context: ctx)
        #expect(report.processed == ["login"])
        #expect(report.failures.map(\.id) == ["bad"])
    }

    // MARK: Xcode runtimes

    @Test func parsesSimulatorRuntimeImages() {
        let plist: [String: Any] = ["images": [[
            "uuid": "A312F7E6-9EBB-4197-BB64-0AE1955E821E",
            "path": ["relative": "file:///Library/Developer/CoreSimulator/Images/A312.dmg"],
            "sourceURL": ["relative": "file:///System/Library/AssetsV2/x.asset/AssetData/Restore/094-56039-099.dmg"],
            "runtimeInfo": ["build": "23F77", "bundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                            "bundlePath": ["relative": "file:///Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS%2026.5.simruntime/"]],
        ], ["uuid": "broken"]]]
        let r = XcodeScanner.runtimeImages(plist)
        #expect(r == [.init(uuid: "A312F7E6-9EBB-4197-BB64-0AE1955E821E", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                            name: "iOS 26.5 (23F77)", image: URL(fileURLWithPath: "/System/Library/AssetsV2/x.asset/AssetData/Restore/094-56039-099.dmg"))])
    }

    @Test func listsLegacyRuntimeBundlesWithUsage() throws {
        try plist("Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 15.0.simruntime/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-15-0"])
        try plist("Library/Developer/CoreSimulator/Devices/U1/device.plist", ["runtime": "com.apple.CoreSimulator.SimRuntime.iOS-15-0"])
        let items = XcodeScanner.simulatorRuntimes(scope)
        #expect(items.map(\.name) == ["iOS 15.0"])
        #expect(items[0].detail?.hasPrefix("Utilisé par 1 simulateur(s)") == true)
        #expect(!items[0].autoSelect)
        #expect(XcodeScanner.runtimeUsage(in: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices"))
                == ["com.apple.CoreSimulator.SimRuntime.iOS-15-0": 1])
    }

    // MARK: Mail

    func makeAccountsDB(_ rows: [(id: String, type: String, title: String, active: Int)]) throws {
        let url = home.appendingPathComponent("Library/Accounts/Accounts4.sqlite")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE ZACCOUNTTYPE (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER VARCHAR);
            CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZACCOUNTTYPE INTEGER, ZIDENTIFIER VARCHAR, ZACCOUNTDESCRIPTION VARCHAR, ZUSERNAME VARCHAR, ZACTIVE INTEGER);
            """
        for (i, r) in rows.enumerated() {
            sql += "INSERT INTO ZACCOUNTTYPE VALUES (\(i + 1), '\(r.type)');"
            sql += "INSERT INTO ZACCOUNT VALUES (\(i + 1), \(i + 1), '\(r.id)', '\(r.title)', NULL, \(r.active));"
        }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func classifiesMailAccounts() {
        #expect(MailTrashScanner.accountKind("com.apple.account.IMAP") == .imap)
        #expect(MailTrashScanner.accountKind("com.apple.account.POP") == .pop)
        #expect(MailTrashScanner.accountKind("com.apple.account.Exchange") == .exchange)
        #expect(MailTrashScanner.accountKind("com.apple.account.AppleAccount") == .icloud)
        #expect(MailTrashScanner.accountKind("com.apple.account.SMTP") == .other)
        let a = MailTrashScanner.mailAccounts([["id": "A", "type": "com.apple.account.IMAP", "active": "0"], ["type": "x"]])
        #expect(a.count == 1 && a["A"]?.recoverable == false)
    }

    @Test func mailAttachmentsFollowAccountType() async throws {
        try makeAccountsDB([("IMAP-ID", "com.apple.account.IMAP", "Perso", 1), ("POP-ID", "com.apple.account.POP", "Vieux", 1)])
        try file("Library/Mail/V10/IMAP-ID/INBOX.mbox/X/Data/Attachments/1/a.pdf")
        try file("Library/Mail/V10/POP-ID/INBOX.mbox/X/Data/Attachments/2/b.pdf")
        try file("Library/Mail/V10/OTHER-ID/INBOX.mbox/X/Data/Attachments/3/c.pdf")
        try file("Library/Mail/V10/IMAP-ID/Deleted Messages.mbox/X/Data/1/Messages/9.emlx")
        try file("Library/Mail/V10/IMAP-ID/Deleted Messages.mbox/X/Data/Attachments/9/d.pdf")
        try file("Library/Mail/V10/POP-ID/Deleted Messages.mbox/X/Data/1/Messages/8.emlx")

        let accounts = try #require(MailTrashScanner.mailAccounts(scope))
        #expect(accounts["IMAP-ID"]?.title == "Perso")
        let g = MailTrashScanner.mail(scope, accounts: accounts).pruned()
        let byGroup = Dictionary(uniqueKeysWithValues: g.groups.map { ($0.id, $0) })
        #expect(byGroup["cleanup.mail.IMAP-ID"]?.title == "Perso")
        // The IMAP trash mailbox is offered whole under the trash bins, not here.
        #expect(byGroup["cleanup.mail.IMAP-ID"]?.items.count == 1)
        #expect(byGroup["cleanup.mail.POP-ID"]?.items.count == 1)
        if !NSWorkspaceRunning.mail {
            #expect(g.defaultSelection.count == 1)
            #expect(byGroup["cleanup.mail.IMAP-ID"]?.defaultSelection.count == 1)
        }
        #expect(byGroup["cleanup.mail.OTHER-ID"]?.items.first?.detail?.contains("Compte inconnu") == true)

        // No database (no Full Disk Access): previous behaviour, every account but "Sur mon Mac".
        let open = MailTrashScanner.mail(scope, accounts: nil).pruned()
        #expect(open.allItems.count == 4)

        let trash = try #require(MailTrashScanner.mailTrashes(scope, accounts: accounts))
        #expect(trash.allItems.map(\.url?.lastPathComponent) == ["Data"])
        #expect(trash.allItems[0].url?.path.contains("IMAP-ID") == true)
        #expect(trash.defaultSelection.isEmpty)
        #expect(trash.allItems.allSatisfy { if case .delete(_, .trash, false) = $0.action { true } else { false } })
        #expect(MailTrashScanner.mailTrashes(scope, accounts: nil) == nil)
    }

    // MARK: iCloud trashes

    @Test func findsEveryICloudTrashOnce() async throws {
        try file("Library/Mobile Documents/com~apple~CloudDocs/.Trash/a.txt")
        try file("Library/Mobile Documents/.Trash/b.txt")
        try file("Library/Mobile Documents/com~apple~Pages/Documents/.Trash/c.pages")
        try file("Library/Mobile Documents/com~apple~Pages/Documents/keep.pages")
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/CloudStorage/iCloud Drive"),
                                  withDestinationURL: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        let trash = try #require(await scan().first { $0.id == "cleanup.trash" })
        let icloud = trash.groups.filter { $0.id.hasPrefix("cleanup.trash.icloud") }
        #expect(Set(icloud.flatMap(\.allItems).compactMap(\.url?.lastPathComponent)) == ["a.txt", "b.txt", "c.pages"])
        #expect(icloud.flatMap(\.allItems).count == 3)
        #expect(icloud.allSatisfy { $0.defaultSelection.isEmpty })
        #expect(icloud.contains { $0.id == "cleanup.trash.icloud" })
    }
}
