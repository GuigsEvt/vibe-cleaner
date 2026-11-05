import Foundation
import Testing
@testable import VibeCleanerCore

/// `execute` of modules in simulation, with every action kind they produce, on files of a temporary folder.
/// Commands are harmless (`/usr/bin/touch` on a marker); nothing may run or move.
@Suite struct ModuleDryRunEdgeTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("vc-mod-dry-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp.appendingPathComponent("home"), withIntermediateDirectories: true)
    }

    func file(_ rel: String) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func protectionMovesAndRunsNothingInDryRun() async throws {
        let q = Quarantine(root: tmp.appendingPathComponent("Q"))
        let marker = tmp.appendingPathComponent("ran")
        let threat = try file("Downloads/evil.command")
        let agent = try file("LaunchAgents/com.evil.plist")
        let daemon = try file("LaunchDaemons/com.evil.daemon.plist")
        let recent = try file("SharedFileList/recent.sfl3")
        let db = try file("Chrome/History")
        let items = [
            ResultItem(id: "f", name: "f", url: threat, action: .custom("quarantine-file")),
            ResultItem(id: "a", name: "a", url: agent, action: .custom("quarantine-launch-user")),
            ResultItem(id: "d", name: "d", url: daemon, action: .custom("quarantine-launch-system")),
            ResultItem(id: "r", name: "r", url: recent, action: .custom(Privacy.removeRecentList)),
            ResultItem(id: "b", name: "b", url: db, action: .custom("browser:com.google.Chrome:chromeHistory")),
            ResultItem(id: Cron.idPrefix + "* * * * * /tmp/x", name: "cron", action: .custom(Cron.removeKey)),
            ResultItem(id: "t", name: "t", action: .command(executable: "/usr/bin/touch", arguments: [marker.path], admin: false)),
            ResultItem(id: "ta", name: "ta", action: .command(executable: "/usr/bin/touch", arguments: [marker.path], admin: true)),
        ]
        let ctx = ModuleContext(dryRun: true, home: tmp.appendingPathComponent("home"))
        let r = await ProtectionModule(quarantine: q).execute(items, context: ctx)
        #expect(Set(r.processed) == Set(items.map(\.id)))
        #expect(r.failures.isEmpty)
        for u in [threat, agent, daemon, recent, db] { #expect(fm.fileExists(atPath: u.path), "\(u.lastPathComponent)") }
        #expect(!fm.fileExists(atPath: marker.path))
        #expect(!fm.fileExists(atPath: q.root.path), "la simulation a créé la quarantaine")
    }

    @Test func protectionRefusesUnknownKeysWithoutTouchingTheFile() async throws {
        let q = Quarantine(root: tmp.appendingPathComponent("Q"))
        let f = try file("x.bin")
        let items = [ResultItem(id: "u", name: "u", url: f, action: .custom("no-such-action")),
                     ResultItem(id: "n", name: "n", action: .custom("quarantine-file"))]
        // Real mode on purpose (dry-run marks every custom item processed before looking at it): both items are refused
        // or skipped before any process lookup, quarantine or command.
        let r = await ProtectionModule(quarantine: q).execute(items, context: ModuleContext(home: tmp.appendingPathComponent("home")))
        #expect(r.failures.map(\.id) == ["u"])
        #expect(r.processed.isEmpty) // "n" has no URL: skipped silently
        #expect(fm.fileExists(atPath: f.path))
        #expect(q.list().isEmpty)
    }

    /// Admin commands that carry a scanned path (launchd jobs of /Library) are revalidated against the ignore list
    /// by the executor, whatever the module (V3 known issue A, fixed).
    @Test func applicationsRevalidatesAdminCommandsAgainstExclusions() async throws {
        let plist = try file("Library/LaunchDaemons/com.gone.daemon.plist")
        let item = ResultItem(id: plist.path, name: "d", url: plist,
                              action: PerformanceModule.removeCommand(plist: plist, domain: "system"))
        let ctx = ModuleContext(dryRun: true, exclusions: [plist.deletingLastPathComponent().path], home: tmp.appendingPathComponent("home"))
        let r = await ApplicationsModule().execute([item], context: ctx)
        let cleanup = await CleanupModule().execute([item], context: ctx)
        let performance = await PerformanceModule().execute([item], context: ctx)
        #expect(cleanup.failures.map(\.id) == [item.id])
        #expect(r.failures.map(\.id) == [item.id])
        #expect(performance.failures.map(\.id) == [item.id])
    }
}
