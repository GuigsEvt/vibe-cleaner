import Foundation
import Testing
@testable import VibeCleanerCore

/// Lot B: safer default selection in Nettoyage, forbidden home trees in SafeRemover, revalidation before deletion.
/// Everything lives in a temporary fake home; nothing is removed outside it (dry runs only).
@Suite struct LotBTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("vc-b-\(UUID().uuidString.prefix(8))")
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

    /// Backdates an item and its direct children.
    func age(_ path: String, by seconds: TimeInterval = 86_400) throws {
        let url = home.appendingPathComponent(path), old = Date(timeIntervalSinceNow: -seconds)
        for u in [url] + ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []) {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path)
        }
    }

    func item(_ g: ResultGroup?, _ name: String) -> ResultItem? { g?.allItems.first { $0.url?.lastPathComponent == name } }

    // MARK: 1. Darwin caches

    @Test func darwinCachesSkipSystemEntriesAndNeedAKnownOwner() throws {
        for name in ["mds", "com.example.PersistedState", "com.apple.Safari", "org.llvm.clang.me", "com.example.app", "org.unknown.tool"] {
            try file("darwin/\(name)/blob")
        }
        let names = Set(CacheScanner.darwinCacheEntries(home.appendingPathComponent("darwin")).map(\.lastPathComponent))
        #expect(names == ["com.example.app", "org.unknown.tool"])
        let installed: Set<String> = ["com.example.app"]
        #expect(CacheScanner.isInstalledOwner("com.example.app", installed: installed, lookUp: { _ in false }))
        #expect(CacheScanner.isInstalledOwner("com.example.App.helper", installed: installed, lookUp: { _ in false }))
        #expect(!CacheScanner.isInstalledOwner("org.unknown.tool", installed: installed, lookUp: { _ in false }))
        #expect(CacheScanner.isInstalledOwner("org.unknown.tool", installed: [], lookUp: { $0 == "org.unknown.tool" }))
    }

    // MARK: 2. Recently written caches

    @Test func recentlyWrittenCacheIsNotSelected() throws {
        try file("Library/Caches/com.example.fresh/data")
        try file("Library/Caches/com.example.old/data")
        try file("Library/Caches/com.example.oldDirFreshChild/data")
        try age("Library/Caches/com.example.old")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)],
                             ofItemAtPath: home.appendingPathComponent("Library/Caches/com.example.oldDirFreshChild").path)
        let g = CacheScanner.userCaches(scope)
        let fresh = try #require(item(g, "com.example.fresh"))
        #expect(!fresh.autoSelect && fresh.detail?.contains("moins de 10 min") == true)
        #expect(item(g, "com.example.oldDirFreshChild")?.autoSelect == false)
        #expect(item(g, "com.example.old")?.autoSelect == true)
    }

    // MARK: 3. Admin items

    @Test func adminItemIsNeverSelected() throws {
        // Read only: a root-owned file outside the home needs the admin batch.
        let it = try #require(scope.item(URL(fileURLWithPath: "/usr/bin/true"), mode: .trash, auto: true))
        #expect(it.needsAdmin && !it.autoSelect)
    }

    // MARK: 4. Hardcoded app folders

    @Test func userContentFoldersGoToTheTrash() throws {
        try file("Library/Application Support/Spotify/PersistentCache/Storage/a")
        try file("Library/Application Support/Adobe/Common/Media Cache Files/b")
        try file("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic/song")
        let g = CacheScanner.userCaches(scope)
        let mode = { (name: String) -> RemovalMode? in
            if case .delete(_, let m, _) = item(g, name)?.action { m } else { nil }
        }
        #expect(mode("Storage") == .trash && mode("iMusic") == .trash)
        #expect(mode("Media Cache Files") == .permanent)
        #expect(g.defaultSelection.isEmpty)
        let trash: Set<String> = ["Telegram", "WeChat", "Tencent Video", "QQ Music", "Spotify"]
        for h in CacheScanner.hardcoded { #expect(h.mode == (trash.contains(h.label) ? .trash : .permanent), "\(h.label)") }
    }

    // MARK: 5. Mail without the accounts database

    @Test func mailAttachmentsUnselectedWithoutAccounts() throws {
        try file("Library/Mail/V10/ACCOUNT-ID/INBOX.mbox/X/Data/Attachments/42/doc.pdf")
        let g = MailTrashScanner.mail(scope, accounts: nil).pruned()
        let it = try #require(g.allItems.first)
        #expect(!it.autoSelect)
        #expect(it.detail?.contains("Type de compte inconnu") == true)
    }

    // MARK: 6. Slack downloads

    @Test func slackDownloadSelectedOnlyWhenItIsStillTheDownloadedFile() throws {
        let start = Date(timeIntervalSinceNow: -40 * 86_400)
        let match = try file("Downloads/match.pdf")
        try fm.setAttributes([.creationDate: start], ofItemAtPath: match.path)
        try file("Downloads/replaced.pdf")                       // created now: another file under the same name
        let outside = try file("Documents/elsewhere.pdf")
        try fm.setAttributes([.creationDate: start], ofItemAtPath: outside.path)
        try fm.createDirectory(at: home.appendingPathComponent("Downloads/folder"), withIntermediateDirectories: true)
        try file("Downloads/folder/inner")
        let ms = start.timeIntervalSince1970 * 1000
        let records = ["match.pdf", "replaced.pdf", "folder"].map { ["downloadPath": home.appendingPathComponent("Downloads/\($0)").path, "startTime": ms] }
            + [["downloadPath": outside.path, "startTime": ms]]
        try file("Library/Application Support/Slack/storage/slack-downloads", data: try JSONSerialization.data(withJSONObject: records))
        let g = MailTrashScanner.slackDownloads(scope)
        #expect(g.allItems.count == 4)
        #expect(Set(g.allItems.filter(\.autoSelect).compactMap { $0.url?.lastPathComponent }) == ["match.pdf"])
    }

    // MARK: 7. Forbidden home trees and revalidation

    @Test func forbiddenHomeTreesAreRefused() throws {
        let r = SafeRemover(home: home.path)
        for p in ["Library/Keychains", "Library/Keychains/login.keychain-db", "Library/Messages/chat.db", "Library/Accounts/Accounts4.sqlite",
                  "Library/Mail/V10/MailData/Envelope Index", "Pictures/Photos Library.photoslibrary/database",
                  "Library/Containers/com.example.app/Data/Documents/report.txt"] {
            #expect(throws: RemovalError.self, "\(p)") { try r.check(home.appendingPathComponent(p)) }
        }
        for p in ["Library/Mail/V10/ACCOUNT/INBOX.mbox/X/Data/Attachments/42", "Library/Containers/com.example.app/Data/Library/Caches/x",
                  "Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE/seg", "Pictures/holiday.jpg",
                  "Library/MessagesExtra/x"] {
            #expect(throws: Never.self, "\(p)") { try r.check(home.appendingPathComponent(p)) }
        }
    }

    @Test func allowedPathLinkingIntoForbiddenTreeIsRefused() throws {
        try file("Library/Keychains/login.keychain-db")
        let link = home.appendingPathComponent("Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("Library/Keychains"))
        #expect(throws: RemovalError.self) { try SafeRemover(home: home.path).check(link) }
    }

    @Test func deletionModifiedSinceScanIsSkipped() throws {
        let url = try file("Library/Caches/com.example.app/data")
        let mtime = try #require(Junk.modified(url))
        let remover = SafeRemover(dryRun: true, home: home.path)
        func make(_ date: Date?) -> ResultItem { ResultItem(name: "data", url: url, size: 5000, date: date, action: .delete(url, mode: .permanent, admin: false)) }

        let stale = ActionExecutor(remover: remover, revalidatesModificationDate: true).run([make(mtime.addingTimeInterval(-3600))])
        #expect(stale.processed.isEmpty && stale.failures.first?.reason == ActionExecutor.modifiedSinceScan)
        let same = ActionExecutor(remover: remover, revalidatesModificationDate: true).run([make(mtime), make(nil)])
        #expect(same.failures.isEmpty && same.processed.count == 2)
        // Other modules keep their own meaning of `date` (last used, added): no revalidation by default.
        #expect(ActionExecutor(remover: remover).run([make(mtime.addingTimeInterval(-3600))]).failures.isEmpty)
        #expect(fm.fileExists(atPath: url.path))
    }

    // MARK: 8. Symlinks in a trash

    @Test func symlinkInTrashIsCheckedUnresolved() throws {
        try fm.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        let inTrash = home.appendingPathComponent(".Trash/system-link")
        try fm.createSymbolicLink(at: inTrash, withDestinationURL: URL(fileURLWithPath: "/System"))
        let elsewhere = home.appendingPathComponent("system-link")
        try fm.createSymbolicLink(at: elsewhere, withDestinationURL: URL(fileURLWithPath: "/System"))
        let r = SafeRemover(dryRun: true, home: home.path)
        #expect(throws: Never.self) { try r.check(inTrash) }
        #expect(throws: RemovalError.self) { try r.check(elsewhere) }
        #expect(r.remove([inTrash], mode: .permanent).removed == [inTrash])
        // The trash folder itself stays protected.
        #expect(throws: RemovalError.self) { try r.check(home.appendingPathComponent(".Trash")) }
    }

    // MARK: 9. Temporary files

    @Test func newestDateLooksInsideAndSkipsSockets() throws {
        try file("tmp/old/sub/fresh")
        try age("tmp/old")
        let newest = try #require(CacheScanner.newestDate(in: home.appendingPathComponent("tmp/old")))
        #expect(Date().timeIntervalSince(newest) < 600)
        #expect(CacheScanner.newestDate(in: home.appendingPathComponent("tmp/old"), limit: 1) == nil)

        try fm.createDirectory(at: home.appendingPathComponent("s"), withIntermediateDirectories: true)
        let path = home.appendingPathComponent("s/k").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
        }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(bound == 0, "socket path too long: \(path)")
        try age("s", by: 30 * 86_400)
        #expect(CacheScanner.newestDate(in: home.appendingPathComponent("s")) == nil)
    }

    // MARK: 10–11. Quarantine events, broken preferences and backups

    @Test func lsdDatabaseAndBrokenFilesAreNotSelected() throws {
        try file("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
        try file("Library/Preferences/com.example.bad.plist", data: Data("not a plist".utf8))
        let logs = LogScanner.userLogs(scope)
        #expect(item(logs, "com.apple.LaunchServices.QuarantineEventsV2")?.autoSelect == false)
        #expect(item(SystemJunkScanner.brokenPreferences(scope), "com.example.bad.plist")?.autoSelect == false)

        let base = "Library/Application Support/MobileSync/Backup"
        try file("\(base)/FRESH/Manifest.db")
        try file("\(base)/STALE/Manifest.db")
        try age("\(base)/STALE", by: 2 * 3600)
        let backups = SystemJunkScanner.iosBackups(scope)
        #expect(item(backups, "FRESH")?.autoSelect == false)
        #expect(item(backups, "STALE")?.autoSelect == true)
    }

    // MARK: 12. Launch agents

    @Test func launchPlistWithoutProgramIsNotBroken() throws {
        #expect(SystemJunkScanner.launchProgram([:], home: home) == nil)
        #expect(SystemJunkScanner.launchProgram(["Label": "com.google.keystone.agent"], home: home) == nil)
        #expect(SystemJunkScanner.launchProgram(["Label": "x", "Program": ""], home: home) == nil)
        #expect(SystemJunkScanner.launchProgram(["Program": "/nonexistent/vc-agent"], home: home) == "/nonexistent/vc-agent")

        try plist("Library/LaunchAgents/com.google.keystone.agent.plist", ["Label": "com.google.keystone.agent"])
        try plist("Library/LaunchAgents/empty.plist", [:])
        try plist("Library/LaunchAgents/com.example.broken.plist", ["Label": "com.example.broken", "ProgramArguments": ["/nonexistent/vc-agent"]])
        let g = SystemJunkScanner.brokenLaunchAgents(scope)
        #expect(g.allItems.map(\.name) == ["com.example.broken"])
        #expect(g.allItems.first?.detail == "Programme introuvable : /nonexistent/vc-agent")
    }

    // MARK: 13. Document versions

    @Test func documentVersionsAreIrreversibleAndUnselected() {
        let it = SystemJunkScanner.versionItem(home.appendingPathComponent("a.pages"), date: Date(), size: 10, intermediate: true)
        #expect(!it.autoSelect && it.isIrreversible && it.customIsIrreversible)
        #expect(it.detail?.hasPrefix("Version intermédiaire") == true)
    }

    // MARK: 14. Unavailable simulators

    @Test func unavailableSimulatorsDeletedByUDID() {
        let it = XcodeScanner.unavailableItem([("U1", "iPhone 15"), ("U2", "iPad")], base: home, size: 1)
        #expect(it.action == .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "U1", "U2"], admin: false))
        #expect(!it.autoSelect)
    }

    // MARK: 15. Radar

    @Test func radarRefusesWhatSafeRemoverRefuses() {
        let h = "/Users/me"
        for p in ["\(h)/Library/Keychains/login.keychain-db", "\(h)/Pictures/Photos Library.photoslibrary", "\(h)/Library/Mail/V10/MailData",
                  "\(h)/Library/Containers/com.x/Data/Documents/a", "\(h)/Library/Preferences", "\(h)/.Trash", "/Library/Keychains/System.keychain"] {
            #expect(SpaceNode.isProtected(path: p, home: h), "\(p)")
            #expect(SafeRemover.isProtected(path: p, home: h), "\(p)")
        }
        #expect(!SpaceNode.isProtected(path: "\(h)/Pictures/holiday.jpg", home: h))
    }
}
