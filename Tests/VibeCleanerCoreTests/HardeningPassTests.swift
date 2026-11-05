import Foundation
import Testing
@testable import VibeCleanerCore

/// Pre-release hardening pass. Temporary folders only, no privilege, launchctl replaced by /usr/bin/true.
@Suite(.serialized) struct HardeningPassTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: Junk.realPath(fm.temporaryDirectory.path)).appendingPathComponent("vc-hp-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    // MARK: An uninstall never claims another vendor's files

    @Test func vagueOrForeignIdsClaimNothing() {
        #expect(!AppMatch.isSpecificID("com"))
        #expect(!AppMatch.isSpecificID("com.crowdstrike"))
        #expect(!AppMatch.isSpecificID("com..x"))
        #expect(AppMatch.isSpecificID("com.docker.docker"))
        #expect(AppMatch.sameVendor("com.docker.vmnetd", "com.docker.docker"))
        #expect(!AppMatch.sameVendor("com.crowdstrike.falcon.Agent", "com.adware.app"))
    }

    @Test func anAppDeclaringAVagueIdDoesNotTakeOtherDaemons() throws {
        let home = tmp.appendingPathComponent("home"), lib = tmp.appendingPathComponent("Library")
        let daemons = lib.appendingPathComponent("LaunchDaemons"), tools = lib.appendingPathComponent("PrivilegedHelperTools")
        for d in [home.appendingPathComponent("Library"), daemons, tools] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data().write(to: daemons.appendingPathComponent("com.vendor.agent.plist"))
        try Data().write(to: tools.appendingPathComponent("com.vendor.helper"))
        let app = InstalledApp(url: tmp.appendingPathComponent("Ad.app"), bundleID: "com", name: "Ad",
                               privilegedExecutables: ["com.vendor.helper"], embeddedBundleIDs: ["com.vendor.agent"])
        let finder = AppFootprint(home: home, localLibrary: lib, receiptsDir: tmp.appendingPathComponent("receipts"),
                                  darwinDirs: [], binDirs: [], loginItems: [], installed: [app], downloads: false)
        #expect(finder.footprint(of: app).isEmpty)
    }

    // MARK: Permanent deletion never through a linked parent

    @Test func permanentDeletionRefusesALinkedParent() throws {
        let docs = tmp.appendingPathComponent("Documents/Travail")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let thesis = docs.appendingPathComponent("These.docx")
        try Data("x".utf8).write(to: thesis)
        let cache = tmp.appendingPathComponent("cache")
        try fm.createSymbolicLink(at: cache, withDestinationURL: docs)
        let r = SafeRemover(home: tmp.path).remove([cache.appendingPathComponent("These.docx")], mode: .permanent)
        #expect(r.removed.isEmpty && r.failures.count == 1)
        #expect(fm.fileExists(atPath: thesis.path))
    }

    @Test func keysAndPrivacyDatabaseAreForbidden() {
        let home = "/Users/someone"
        #expect(SafeRemover.isProtected(path: "\(home)/.ssh/id_ed25519", home: home))
        #expect(SafeRemover.isProtected(path: "\(home)/.gnupg/pubring.kbx", home: home))
        #expect(SafeRemover.isProtected(path: "\(home)/Library/Application Support/com.apple.TCC/TCC.db", home: home))
        #expect(SafeRemover.isProtected(path: "/private/var/root/.profile", home: home))
    }

    @Test func credentialsPersonalDataAndVolumeMetadataAreForbidden() {
        let home = "/Users/someone"
        for p in [".aws/credentials", ".kube/config", ".netrc", ".password-store/mail.gpg", ".config/gh/hosts.yml",
                  "Library/Calendars/Calendar.sqlitedb", "Library/Application Support/AddressBook/Sources",
                  "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"] {
            #expect(SafeRemover.isProtected(path: "\(home)/\(p)", home: home), "\(p)")
        }
        #expect(SafeRemover.isProtected(path: "/Library/Application Support/com.apple.TCC/TCC.db", home: home))
        #expect(SafeRemover.isProtected(path: "/private/var/vm/sleepimage", home: home))
        #expect(SafeRemover.isProtected(path: "/Volumes/Sauvegarde/Backups.backupdb/Mac/2026-01-01", home: home))
        #expect(SafeRemover.isProtected(path: "/Volumes/Externe/.Spotlight-V100/Store-V2", home: home))
        // Neighbours stay cleanable: other dotfolders, Safari caches, iOS backups.
        #expect(!SafeRemover.isProtected(path: "\(home)/.config/yarn/cache", home: home))
        #expect(!SafeRemover.isProtected(path: "\(home)/Library/Caches/com.apple.Safari/Cache.db", home: home))
        #expect(!SafeRemover.isProtected(path: "\(home)/Library/Application Support/MobileSync/Backup/abc", home: home))
    }

    // MARK: A duplicate copy needs another copy unchanged since its own scan

    @Test func aSameLengthRewriteOfTheKeptCopyBlocksTheDeletion() async throws {
        let home = tmp.appendingPathComponent("home")
        let docs = home.appendingPathComponent("Documents"), dl = home.appendingPathComponent("Downloads")
        for d in [docs, dl] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        let kept = docs.appendingPathComponent("a.bin")
        try content.write(to: kept)
        try content.write(to: dl.appendingPathComponent("a.bin"))
        let m = ClutterModule()
        let groups = await m.scan(context: ModuleContext(home: home)) { _, _ in }
        let set = try #require(groups.first { $0.id == "clutter.duplicates" }?.groups.first)
        let copy = set.items[1]
        #expect(copy.copySet.count == 2)
        let ctx = ModuleContext(dryRun: true, home: home)
        #expect(await m.execute([copy], context: ctx).processed == [copy.id])
        // Same length, other content: only the date tells, and the copy stays.
        try Data(repeating: 7, count: content.count).write(to: kept)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: kept.path)
        let r = await m.execute([copy], context: ctx)
        #expect(r.processed.isEmpty && r.failures.map(\.id) == [copy.id])
    }

    // MARK: Root quarantine reaches the item from its checked parent

    @Test func adminQuarantineRefusesALinkedParent() throws {
        let real = tmp.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data().write(to: real.appendingPathComponent("tool"))
        let link = tmp.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let q = Quarantine(root: tmp.appendingPathComponent("Q"), adminRoot: tmp.appendingPathComponent("zone"))
        #expect(throws: (any Error).self) { try q.adminAddCommand(link.appendingPathComponent("tool"), id: UUID().uuidString, domain: nil) }
    }

    @Test func aParentSwappedAfterTheCheckStopsTheRootMove() throws {
        let dir = tmp.appendingPathComponent("bin")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tool = dir.appendingPathComponent("tool")
        try Data().write(to: tool)
        let q = Quarantine(root: tmp.appendingPathComponent("Q"), adminRoot: tmp.appendingPathComponent("zone"))
        let cmd = try q.adminAddCommand(tool, id: UUID().uuidString, domain: nil, launchctl: "/usr/bin/true")
        // The folder becomes a link to another one holding a file of the same name.
        let other = tmp.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("victim".utf8).write(to: other.appendingPathComponent("tool"))
        try fm.removeItem(at: dir)
        try fm.createSymbolicLink(at: dir, withDestinationURL: other)
        #expect(Shell.run(cmd[0], Array(cmd.dropFirst()), timeout: 30).status != 0)
        #expect(fm.fileExists(atPath: other.appendingPathComponent("tool").path))
    }

    @Test func aRestoreCycleEndsInsteadOfRecursingForever() throws {
        let q = Quarantine(root: tmp.appendingPathComponent("Q"), adminRoot: tmp.appendingPathComponent("zone"))
        let a = tmp.appendingPathComponent("a.txt"), b = tmp.appendingPathComponent("b.txt")
        try Data().write(to: a)
        try Data().write(to: b)
        let ea = try q.add(a, reason: "")
        let eb = try q.add(b, reason: "", linkedTo: ea.id)
        // Edit A's manifest so that it points back to B.
        let manifest = tmp.appendingPathComponent("Q/\(ea.id)/manifest.json")
        var entry = try JSONDecoder().decode(Quarantine.Entry.self, from: Data(contentsOf: manifest))
        entry.linkedTo = eb.id
        try JSONEncoder().encode(entry).write(to: manifest)
        try q.restore(ea.id, remover: SafeRemover(home: tmp.path)) { _ in }
        #expect(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path))
    }

    // MARK: Parsing hostile browser files

    @Test func anExtensionLocaleIsNeverAPath() throws {
        let dir = tmp.appendingPathComponent("ext")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(Extensions.displayName(["name": "__MSG_x__", "default_locale": "../../../../tmp/x"], dir: dir) == nil)
    }

    @Test func lookalikeSearchHostsAreNotTrusted() {
        #expect(Extensions.isHost("www.google.fr", of: "google."))
        #expect(Extensions.isHost("google.co.uk", of: "google."))
        #expect(!Extensions.isHost("google.evil-search.ru", of: "google."))
        #expect(!Extensions.isHost("bing.com.find-it.net", of: "bing.com"))
        #expect(Extensions.homepageReason("https://google.search-now.ru/", managed: false) != nil)
    }

    // MARK: The CLI and the app start from the same selection

    @Test func cardsPickedOneByOneStartEmpty() {
        let dup = ResultGroup(id: "clutter.duplicates", title: "", items: [ResultItem(id: "copy", name: "c", action: .none)])
        let junk = ResultGroup(id: "cleanup.cache", title: "", items: [ResultItem(id: "cache", name: "c", action: .none)])
        #expect(ResultQueries.initialSelection([dup, junk]) == ["cache"])
    }
}
