import Foundation
import Testing
@testable import VibeCleanerCore

/// R1 counter-audit proofs. Temporary folders only, no privilege, launchctl replaced by /usr/bin/true.
@Suite(.serialized) struct SecurityRegressionTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: Junk.realPath(fm.temporaryDirectory.path)).appendingPathComponent("vc-r1-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    func sh(_ script: String, _ args: [String]) -> Int32 {
        Shell.run("/bin/sh", ["-c", script, "sh"] + args, timeout: 30).status
    }

    // MARK: V2-B1 root trash: link planted where the zone should be

    @Test func zoneThatIsALinkIsRefused() throws {
        let src = tmp.appendingPathComponent("parent/item.plist")
        try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src)
        let elsewhere = tmp.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let zone = tmp.appendingPathComponent("zone")
        try fm.createSymbolicLink(at: zone, withDestinationURL: elsewhere)
        let cmd = try ActionExecutor.adminDeleteCommand(src, mode: .trash, rootTrash: zone.path)
        let st = Shell.run(cmd[0], Array(cmd.dropFirst()), timeout: 30).status
        #expect(st == 5)
        #expect(fm.fileExists(atPath: src.path))
        #expect(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    // MARK: V2-C3 residual: guard and action are two steps on the absolute path

    /// Proposed fix: cd into the checked parent and act on ./name: the swap no longer redirects anything.
    @Test func pinnedParentDoesNotRace() throws {
        let parent = tmp.appendingPathComponent("p")
        let victim = tmp.appendingPathComponent("victim")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: parent.appendingPathComponent("target"))
        try Data("precious".utf8).write(to: victim.appendingPathComponent("target"))
        let item = parent.appendingPathComponent("target")
        let guardFix = #"cd -P -- "$(/usr/bin/dirname -- "$1")" 2>/dev/null && [ "$(pwd -P)" = "$2" ] || exit 3; p="./${1##*/}""#
        let script = guardFix + "\n/bin/sleep 1\n" + #"/bin/rm -rf -- "$p" && [ ! -e "$p" ] && [ ! -L "$p" ]"#
        let t = Thread { usleep(400_000)
            try? FileManager.default.moveItem(at: parent, to: parent.deletingLastPathComponent().appendingPathComponent("p-old"))
            try? FileManager.default.createSymbolicLink(at: parent, withDestinationURL: victim) }
        t.start()
        let st = sh(script, [item.path, ActionExecutor.physicalParent(item)!])
        #expect(st == 0)
        #expect(fm.fileExists(atPath: victim.appendingPathComponent("target").path), "victim untouched")
        #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("p-old/target").path), "the checked folder's item is the one removed")
    }

    // MARK: V2-B2 forged manifests

    @Test func forgedIdsNeverReachTheDisk() throws {
        let q = Quarantine(root: tmp.appendingPathComponent("q"), adminRoot: tmp.appendingPathComponent("aq"))
        let victim = tmp.appendingPathComponent("victim")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        let dir = q.root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let forged = #"{"id":"../../victim","originalPath":"/tmp/x","reason":"r","date":0}"#
        try Data(forged.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(q.list().isEmpty)
        #expect(throws: (any Error).self) { try q.purge("../victim") }
        #expect(throws: (any Error).self) { try q.restore("../victim") }
        #expect(fm.fileExists(atPath: victim.path))
    }

    // MARK: V2-B3 Shell.run

    @Test func writingMoreInputThanTheToolReadsDoesNotKillTheProcess() {
        // /usr/bin/true never reads stdin: the writer thread hits a closed pipe (SIGPIPE if not ignored).
        let r = Shell.run("/usr/bin/true", [], input: Data(count: 4_000_000), timeout: 10)
        #expect(r.ok)
    }

    @Test func manyConcurrentCallsDoNotDeadlock() async {
        let start = Date()
        await withTaskGroup(of: Bool.self) { g in
            for _ in 0..<64 { g.addTask { Shell.run("/bin/sh", ["-c", "/usr/bin/head -c 200000 /dev/zero >&2; echo ok"], timeout: 30).stdout == "ok\n" } }
            for await ok in g { #expect(ok) }
        }
        #expect(Date().timeIntervalSince(start) < 30)
    }

    // MARK: V2-C4

    @Test func privateAliasesAreProtected() {
        let r = SafeRemover()
        for p in ["/private/tmp", "/private/var", "/private/var/db/receipts", "/private/etc/hosts", "/etc/hosts", "/Library/Keychains/System.keychain"] {
            #expect(throws: (any Error).self) { try r.check(URL(fileURLWithPath: p)) }
        }
    }

    // MARK: Collector interactions

    @Test func protectionAndApplicationsNeverDeferInsideAVibeCheckCollector() async {
        let collector = AdminCollector()
        let item = ResultItem(id: "tcc", name: "t", action: .command(executable: "/usr/bin/true", arguments: [], admin: true))
        let ctx = ModuleContext(dryRun: true, home: tmp)
        let r = await ActionExecutor.$adminCollector.withValue(collector) { await ProtectionModule().execute([item], context: ctx) }
        #expect(collector.isEmpty && r.deferred.isEmpty && r.processed == ["tcc"])
        let p = await ActionExecutor.$adminCollector.withValue(collector) { await PerformanceModule().execute([item], context: ctx) }
        #expect(!collector.isEmpty && p.deferred == ["tcc"] && p.processed.isEmpty)
    }
}

extension SecurityRegressionTests {
    /// Stop: the tool and a foreground child are both gone when Shell.run returns (no leak observed).
    @Test func stopLeavesNoChildBehind() async throws {
        let task = Task { Shell.run("/bin/sh", ["-c", "/bin/sleep 23.71; true"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let r = await task.value
        #expect(r.stderr.contains("interrompu"))
        try await Task.sleep(for: .milliseconds(200))
        let t0 = Date()
        let left = Shell.run("/usr/bin/pgrep", ["-f", "^/bin/sleep 2[3].71"]).stdout
        let ps = left.isEmpty ? "" : Shell.run("/bin/ps", ["-o", "pid,ppid,pgid,stat,etime,command", "-p", left.split(separator: "\n").joined(separator: ",")]).stdout
        print("LEFT[\(left)] PS[\(ps)] dt=\(Date().timeIntervalSince(t0))")
        #expect(left.isEmpty)
    }
}
