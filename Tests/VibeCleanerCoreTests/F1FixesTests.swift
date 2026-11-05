import Foundation
import Testing
@testable import VibeCleanerCore

/// Fixes of the F1 wave (V1/V2/V3/V4). Temporary folders and dry-run only; the commands started are
/// `/bin/sh`, `/bin/sleep`, `/bin/cat`, `/usr/bin/head` and `/usr/bin/true`. No administrator prompt.
@Suite struct F1FixesTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        tmp = URL(fileURLWithPath: Junk.realPath(fm.temporaryDirectory.path)).appendingPathComponent("vc-f1-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    // MARK: Shell.run (V2-B3)

    @Test func stderrFloodDoesNotDeadlock() {
        // 1 MB on stderr before stdout ends: the old sequential read blocked forever on the full pipe.
        let r = Shell.run("/bin/sh", ["-c", "/usr/bin/head -c 1000000 /dev/zero >&2; echo done"], timeout: 20)
        #expect(r.ok)
        #expect(r.stdout == "done\n")
        #expect(r.stderr.utf8.count == 1_000_000)
    }

    @Test func timeoutTerminatesTheTool() {
        let start = Date()
        let r = Shell.run("/bin/sleep", ["30"], timeout: 0.5)
        #expect(!r.ok)
        #expect(r.stderr.contains("délai dépassé"))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func cancellationTerminatesTheTool() async {
        let task = Task { Shell.run("/bin/sleep", ["30"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let r = await task.value
        #expect(!r.ok && r.stderr.contains("interrompu"))
    }

    @Test func inputGoesToStdinAndStdinIsOtherwiseEmpty() {
        #expect(Shell.run("/bin/cat", [], input: Data("bonjour".utf8)).stdout == "bonjour")
        #expect(Shell.run("/bin/cat").stdout.isEmpty)
    }

    // MARK: Admin batch (V2-M5)

    @Test func adminAppleScriptSplitsLargeBatchesWithGlobalIndexes() {
        let commands = (0..<450).map { ["/usr/bin/true", String($0)] }
        let script = Shell.adminAppleScript(commands, prompt: "p")
        #expect(script.components(separatedBy: "do shell script").count - 1 == 3)
        #expect(script.contains("VCABORT:200:") && script.contains("VCABORT:400:"))
        #expect(script.contains("VCFAIL:449") && !script.contains("VCFAIL:450"))
        // Bytes cap: huge arguments give one chunk per command, never an empty chunk.
        let big = (0..<3).map { _ in ["/usr/bin/true", String(repeating: "a", count: 150_000)] }
        #expect(Shell.adminAppleScript(big, prompt: "p").components(separatedBy: "do shell script").count - 1 == 3)
    }

    @Test func batchOutputParsing() throws {
        #expect(try Shell.parseBatchOutput("VCFAIL:1\rVCFAIL:3\r", count: 5).get() == [1, 3])
        #expect(try Shell.parseBatchOutput("VCFAIL:1\nVCABORT:200:-128", count: 203).get() == Set([1, 200, 201, 202]))
        guard case .failure(let f) = Shell.parseBatchOutput("VCABORT:0:-128", count: 3) else { Issue.record("expected failure"); return }
        #expect(f.message == "Autorisation annulée")
    }

    // MARK: Shared admin prompt (V4 Vibe Check)

    @Test func collectorDefersAdminWorkUntilFlush() async throws {
        let collector = AdminCollector()
        let a = ResultItem(id: "a", name: "a", size: 10, action: .command(executable: "/usr/bin/true", arguments: [], admin: true))
        let b = ResultItem(id: "b", name: "b", size: 20, action: .command(executable: "/usr/bin/true", arguments: [], admin: true))
        let plain = ResultItem(id: "c", name: "c", action: .command(executable: "/usr/bin/true", arguments: [], admin: false))
        let executor = ActionExecutor(remover: SafeRemover(dryRun: true))
        let (r1, r2) = ActionExecutor.$adminCollector.withValue(collector) { (executor.run([a, plain]), executor.run([b])) }
        #expect(r1.processed == ["c"] && r1.deferred == ["a"])
        #expect(r2.processed.isEmpty && r2.deferred == ["b"])
        #expect(collector.ids == ["a", "b"])

        let outcome = await collector.flush(dryRun: true)
        #expect(collector.isEmpty)
        #expect(Set(outcome.report.processed) == ["a", "b"] && outcome.report.freedBytes == 30)
        var m1 = r1
        m1.merge(outcome.report(for: ["a", "c"]))
        #expect(m1.processed == ["c", "a"] && m1.freedBytes == 10 && m1.deferred.isEmpty)
        #expect(outcome.report(for: ["b"]).freedBytes == 20)
        // Without a collector nothing changes.
        #expect(executor.run([a]).processed == ["a"])
    }

    @Test func collectorFlushHonoursStop() async {
        let collector = AdminCollector()
        let a = ResultItem(id: "a", name: "a", action: .command(executable: "/usr/bin/true", arguments: [], admin: true))
        _ = ActionExecutor.$adminCollector.withValue(collector) { ActionExecutor(remover: SafeRemover(dryRun: true)).run([a]) }
        let task = Task { () -> AdminCollector.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await collector.flush(dryRun: false) // cancelled: never reaches osascript
        }
        let outcome = await task.value
        #expect(outcome.report.failures.map(\.reason) == [ExecutionProgress.stoppedReason])
    }

    // MARK: SafeRemover (V2-C4)

    @Test func systemSecretsAreForbidden() {
        let r = SafeRemover()
        for p in ["/private/etc/hosts", "/etc/hosts", "/Library/Keychains/System.keychain", "/Library/Security/x"] {
            #expect(throws: RemovalError.self, "\(p)") { try r.check(URL(fileURLWithPath: p)) }
        }
    }

    @Test func homeReachedThroughASymlinkStaysProtected() throws {
        let realHome = tmp.appendingPathComponent("real")
        try fm.createDirectory(at: realHome.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: realHome)
        let r = SafeRemover(dryRun: true, home: link.path)
        #expect(throws: RemovalError.self) { try r.check(realHome.appendingPathComponent("Documents")) }
        #expect(throws: RemovalError.self) { try r.check(link.appendingPathComponent("Documents")) }
        let ex = SafeRemover(dryRun: true, userExclusions: [link.appendingPathComponent("Documents").path], home: "/nonexistent")
        #expect(throws: RemovalError.self) { try ex.check(realHome.appendingPathComponent("Documents/a")) }
    }

    // MARK: Cleanup

    @Test func cleanupNeedsMailXcodeAndSimulatorClosed() {
        let m = CleanupModule()
        func dep(_ p: String) -> String? {
            m.appDependency(of: ResultItem(name: "x", url: URL(fileURLWithPath: p), action: .none))?.bundleID
        }
        #expect(dep("/Users/me/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/a.pdf") == "com.apple.mail")
        #expect(dep("/Users/me/Library/Mail/V10/x") == "com.apple.mail")
        #expect(dep("/Users/me/Library/Developer/Xcode/DerivedData/P") == "com.apple.dt.Xcode")
        #expect(dep("/Users/me/Library/Developer/CoreSimulator/Caches/x") == "com.apple.iphonesimulator")
        #expect(dep("/Users/me/Library/Caches/com.foo") == nil)
    }

    @Test func rootTrashIsOfferedUnselected() throws {
        let zone = tmp.appendingPathComponent("zone")
        let held = zone.appendingPathComponent("AbCdEf12/com.vendor.helper.plist")
        try fm.createDirectory(at: held.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: held)
        let s = JunkScope(context: ModuleContext(dryRun: true, home: tmp.appendingPathComponent("home")), system: false, running: [])
        var g = ResultGroup(id: "cleanup.trash", title: "Corbeilles")
        MailTrashScanner.rootTrash(&g, s, root: zone)
        let items = g.groups.first { $0.id == "cleanup.trash.admin" }?.items ?? []
        #expect(items.map(\.name) == ["com.vendor.helper.plist"])
        #expect(items.first?.url == zone.appendingPathComponent("AbCdEf12") && items.first?.autoSelect == false)
        guard case .delete(_, .permanent, _) = items.first?.action else { Issue.record("not a permanent delete"); return }
    }

    @Test func brokenAgentsUseTheSharedRemoveCommand() throws {
        let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.x.plist")
        guard case .command(_, let args, true) = PerformanceModule.removeCommand(plist: plist, domain: "system") else {
            Issue.record("not admin"); return
        }
        #expect(Array(args.dropFirst(2)) == ["sh", plist.path, "/Library/LaunchDaemons", ActionExecutor.rootTrash, "system"])
        #expect(!args.contains { $0.contains(".Trash/") })
    }

    // MARK: Performance (V4 drift 1)

    @Test func programUnderAnUnreadableFolderIsNeverBroken() throws {
        let locked = tmp.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var item = LaunchItem(plist: tmp.appendingPathComponent("a.plist"), scope: .daemon, label: "dev.vc.vpn")
        item.program = locked.appendingPathComponent("bin/daemon").path
        #expect(!item.isBroken)
        #expect(!PerformanceModule.resultItem(item, uid: 501).autoSelect)
        item.program = tmp.appendingPathComponent("gone/daemon").path
        #expect(item.isBroken)
    }

    @Test func appleLabelsAreNeverListed() throws {
        let dir = tmp.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "com.apple.fake", "Program": "/bin/ls"], format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("dev.vc.disguised.plist"))
        #expect(LaunchItem.parse(dir.appendingPathComponent("dev.vc.disguised.plist"), scope: .userAgent) == nil)
    }

    // MARK: Applications

    @Test func appleAppStoreAppsAreRemovableButNotSystemOnes() {
        let pages = InstalledApp(url: URL(fileURLWithPath: "/Applications/Pages.app"), bundleID: "com.apple.iWork.Pages", name: "Pages", source: .appStore)
        let safari = InstalledApp(url: URL(fileURLWithPath: "/Applications/Safari.app"), bundleID: "com.apple.Safari", name: "Safari")
        let system = InstalledApp(url: URL(fileURLWithPath: "/System/Applications/Notes.app"), bundleID: "com.apple.Notes", name: "Notes",
                                  source: .appStore, isSystem: true)
        #expect(!pages.isProtected)
        #expect(safari.isProtected && system.isProtected)
    }

    @Test func noPromptingFolderIsReadWithoutFullDiskAccess() throws {
        let home = tmp.appendingPathComponent("home")
        let urls = ["Desktop/a.dmg", "Documents/b.pkg", "Projets/c.dmg", "Downloads/d.dmg"].map { home.appendingPathComponent($0) }
        for u in urls {
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        #expect(InstallerSearch.filter(urls, home: home).map(\.lastPathComponent) == ["c.dmg"])
        #expect(InstallerSearch.filter(urls, home: home, fullDiskAccess: true).map(\.lastPathComponent) == ["a.dmg", "b.pkg", "c.dmg"])

        let app = InstalledApp(url: home.appendingPathComponent("Applications/Firefox.app"), bundleID: "org.mozilla.firefox", name: "Firefox")
        let without = AppFootprint(home: home, localLibrary: tmp.appendingPathComponent("L"), receiptsDir: tmp.appendingPathComponent("r"), installed: [app])
        #expect(without.downloads.isEmpty)
        try Data("x".utf8).write(to: home.appendingPathComponent("Downloads/Firefox 131.dmg"))
        let with = AppFootprint(home: home, localLibrary: tmp.appendingPathComponent("L"), receiptsDir: tmp.appendingPathComponent("r"),
                                installed: [app], downloads: true)
        #expect(with.footprint(of: app).map(\.lastPathComponent) == ["Firefox 131.dmg"])
    }

    /// V4: the daemon of /Library is stopped (admin batch) before the user-owned bundle goes to the Trash.
    @Test func uninstallStopsDaemonsBeforeTrashingTheBundle() async throws {
        let home = tmp.appendingPathComponent("home")
        let bundle = home.appendingPathComponent("Applications/Foo.app")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let daemon = tmp.appendingPathComponent("Library/LaunchDaemons/com.foo.helper.plist")
        try fm.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: daemon)
        let items = [
            ResultItem(id: bundle.path, name: "Foo", url: bundle, action: .delete(bundle, mode: .trash, admin: false)),
            ResultItem(id: "\(bundle.path)|\(daemon.path)", name: "helper", url: daemon,
                       action: PerformanceModule.removeCommand(plist: daemon, domain: "system")),
        ]
        let order = OrderBox()
        let r = await ExecutionProgress.$onItem.withValue({ order.add($0.id) }) {
            await ApplicationsModule().execute(items, context: ModuleContext(dryRun: true, home: home))
        }
        #expect(r.failures.isEmpty)
        #expect(r.processed == [items[1].id, items[0].id])
        #expect(order.all == [items[1].id, items[0].id])
        // Applications never defers its admin batch to a shared collector.
        let collector = AdminCollector()
        let r2 = await ActionExecutor.$adminCollector.withValue(collector) {
            await ApplicationsModule().execute(items, context: ModuleContext(dryRun: true, home: home))
        }
        #expect(collector.isEmpty && r2.deferred.isEmpty && r2.processed.count == 2)
    }

    final class OrderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }
}
