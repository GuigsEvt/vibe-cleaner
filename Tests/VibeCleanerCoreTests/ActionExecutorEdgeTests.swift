import Foundation
import Testing
@testable import VibeCleanerCore

/// Executor edge cases. Everything runs either in dry-run or on files of a temporary folder; the only
/// commands started are `/usr/bin/true`, `/usr/bin/false`, `/bin/test` and `/bin/sh` on scripts whose
/// system calls are replaced by `/usr/bin/true`. No administrator prompt is ever shown.
@Suite struct ActionExecutorEdgeTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("vc-exec-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    // MARK: Outcome and accounting

    @Test func outcomes() {
        var r = ExecutionReport()
        #expect(r.outcome == .empty)
        r.processed = ["a"]
        #expect(r.outcome == .success)
        r.failures = [("b", "x")]
        #expect(r.outcome == .partial)
        r.processed = []
        #expect(r.outcome == .failure)
        #expect(ActionExecutor(remover: SafeRemover(dryRun: true)).run([]).outcome == .empty)
    }

    @Test func informationalRowsAreNeitherProcessedNorFailed() {
        let items = [ResultItem(id: "info", name: "info", action: .none)]
        let r = ActionExecutor(remover: SafeRemover(dryRun: true)).run(items)
        #expect(r.processed.isEmpty && r.failures.isEmpty && r.outcome == .empty)
    }

    @Test func missingFileFailsAndFreesNothing() {
        let missing = tmp.appendingPathComponent("gone.bin")
        let item = ResultItem(name: "gone", url: missing, size: 1_000, action: .delete(missing, mode: .permanent, admin: false))
        let r = ActionExecutor(remover: SafeRemover(home: "/Users/nobody")).run([item])
        #expect(r.processed.isEmpty)
        #expect(r.failures.map(\.id) == [item.id])
        #expect(r.freedBytes == 0)
        #expect(r.log.isEmpty)
    }

    @Test func realDeleteInTempLogsAndCountsTheItemSize() throws {
        let f = tmp.appendingPathComponent("é t'é.bin")
        try Data(count: 100).write(to: f)
        let item = ResultItem(name: "f", url: f, size: 777, action: .delete(f, mode: .permanent, admin: false))
        let r = ActionExecutor(remover: SafeRemover(home: "/Users/nobody")).run([item])
        #expect(r.processed == [item.id])
        #expect(r.freedBytes == 777)
        #expect(r.log == ["Supprimé : \(f.path)"])
        #expect(!fm.fileExists(atPath: f.path))
    }

    @Test func adminDeleteIsRevalidatedBeforeBatching() {
        let sys = URL(fileURLWithPath: "/System/Library/Kernels")
        let excluded = tmp.appendingPathComponent("keep/x")
        let items = [
            ResultItem(id: "sys", name: "sys", size: 1, action: .delete(sys, mode: .permanent, admin: true)),
            ResultItem(id: "ex", name: "ex", size: 1, action: .delete(excluded, mode: .trash, admin: true)),
            ResultItem(id: "ok", name: "ok", size: 5, action: .delete(tmp.appendingPathComponent("y"), mode: .trash, admin: true)),
        ]
        let remover = SafeRemover(dryRun: true, userExclusions: [tmp.appendingPathComponent("keep").path], home: "/Users/nobody")
        let r = ActionExecutor(remover: remover).run(items)
        #expect(r.failures.map(\.id) == ["sys", "ex"])
        #expect(r.processed == ["ok"])
        #expect(r.freedBytes == 5)
    }

    @Test func userCommandFailuresCarryStatusOrStderr() {
        let items = [
            ResultItem(id: "false", name: "false", action: .command(executable: "/usr/bin/false", arguments: [], admin: false)),
            ResultItem(id: "absent", name: "absent", action: .command(executable: tmp.appendingPathComponent("nope").path, arguments: [], admin: false)),
            ResultItem(id: "true", name: "true", action: .command(executable: "/usr/bin/true", arguments: ["a b", "c'd"], admin: false)),
        ]
        let r = ActionExecutor(remover: SafeRemover(home: "/Users/nobody")).run(items)
        #expect(r.processed == ["true"])
        let reasons = Dictionary(uniqueKeysWithValues: r.failures.map { ($0.id, $0.reason) })
        #expect(reasons["false"] == "code 1")
        #expect(reasons["absent"]?.isEmpty == false)
        #expect(r.log == ["Exécuté : /usr/bin/true a b c'd"])
    }

    @Test func customErrorsAreReportedPerItem() {
        struct Boom: Error {}
        let items = [ResultItem(id: "a", name: "a", size: 3, action: .custom("ok")),
                     ResultItem(id: "b", name: "b", size: 4, action: .custom("boom"))]
        let r = ActionExecutor(remover: SafeRemover(home: "/Users/nobody")).run(items) { _, key in
            if key == "boom" { throw Boom() }
        }
        #expect(r.processed == ["a"])
        #expect(r.failures.map(\.id) == ["b"])
        #expect(r.freedBytes == 3)
    }

    @Test func defaultCustomHandlerRefuses() {
        let r = ActionExecutor(remover: SafeRemover(home: "/Users/nobody")).run([ResultItem(id: "c", name: "c", action: .custom("x"))])
        #expect(r.failures.map(\.id) == ["c"])
    }

    // MARK: Progress and cancellation

    @Test func progressSeesEveryItemIncludingInformationalOnes() async {
        let box = Box()
        let items = [ResultItem(id: "n", name: "n", action: .none), ResultItem(id: "c", name: "c", action: .custom("k"))]
        _ = await Task {
            ExecutionProgress.$onItem.withValue({ box.add($0.id) }) {
                ActionExecutor(remover: SafeRemover(dryRun: true)).run(items)
            }
        }.value
        #expect(box.all == ["n", "c"])
    }

    @Test func cancelledBeforeStartRunsNothing() async {
        let box = Box()
        let items = [ResultItem(id: "a", name: "a", action: .custom("k")),
                     ResultItem(id: "i", name: "i", action: .none),
                     ResultItem(id: "b", name: "b", action: .command(executable: "/usr/bin/true", arguments: [], admin: true))]
        // Dry-run, so a regression could never reach the administrator prompt.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ExecutionProgress.$onItem.withValue({ box.add($0.id) }) {
                ActionExecutor(remover: SafeRemover(dryRun: true)).run(items)
            }
        }
        let r = await task.value
        #expect(box.all.isEmpty)
        #expect(r.processed.isEmpty)
        #expect(r.failures.map(\.id) == ["a", "b"]) // informational rows are not "stopped"
        #expect(r.failures.allSatisfy { $0.reason == ExecutionProgress.stoppedReason })
    }

    @Test func cancellingInsideACustomActionStopsTheRestAndTheAdminBatch() async {
        let items = [ResultItem(id: "root1", name: "root1", size: 10, action: .command(executable: "/usr/bin/true", arguments: [], admin: true)),
                     ResultItem(id: "stop", name: "stop", action: .custom("k")),
                     ResultItem(id: "later", name: "later", action: .custom("k")),
                     ResultItem(id: "root2", name: "root2", action: .delete(tmp.appendingPathComponent("z"), mode: .trash, admin: true))]
        let r = await Task {
            ActionExecutor(remover: SafeRemover(dryRun: true)).run(items) { _, _ in }
        }.value
        #expect(r.processed.count == 4) // control: nothing cancelled

        let cancelled = await Task {
            ExecutionProgress.$onItem.withValue({ item in
                if item.id == "stop" { withUnsafeCurrentTask { $0?.cancel() } }
            }) {
                ActionExecutor(remover: SafeRemover(dryRun: true)).run(items) { _, _ in }
            }
        }.value
        #expect(cancelled.processed == ["stop"])
        #expect(Set(cancelled.failures.map(\.id)) == ["root1", "later", "root2"])
        #expect(cancelled.freedBytes == 0)
    }

    // MARK: adminDeleteCommand (scripts run without privileges on temporary folders)

    /// Physical spelling of the temporary folder (/private/var/...): what `pwd -P` prints.
    var real: URL { URL(fileURLWithPath: Junk.realPath(tmp.path)) }

    func runAdmin(_ cmd: [String], replacing tool: String? = nil) -> ShellResult {
        var c = cmd
        if let tool { c[2] = c[2].replacingOccurrences(of: tool, with: "/usr/bin/true") }
        return Shell.run(c[0], Array(c.dropFirst()))
    }

    @Test func adminTrashMovesIntoAFreshFolderOfTheRootTrash() throws {
        let zone = real.appendingPathComponent("zone").path
        var dests: [String] = []
        for dir in ["A", "B"] {
            let src = real.appendingPathComponent("\(dir)/Cache")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            let r = runAdmin(try ActionExecutor.adminDeleteCommand(src, mode: .trash, rootTrash: zone))
            #expect(r.ok, "\(r.stderr)")
            #expect(!fm.fileExists(atPath: src.path))
            dests = try fm.contentsOfDirectory(atPath: zone)
        }
        // Same-named items never collide: one folder each, the name kept inside.
        #expect(dests.count == 2)
        for d in dests { #expect(try fm.contentsOfDirectory(atPath: "\(zone)/\(d)") == ["Cache"]) }
    }

    /// V2-B1: a symlink planted where the item goes is never followed (the old `mv` into ~/.Trash/<name> was).
    @Test func adminTrashIgnoresALinkPlantedInTheUsersTrash() throws {
        let victim = real.appendingPathComponent("LaunchDaemons")
        let trash = real.appendingPathComponent(".Trash")
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let src = real.appendingPathComponent("com.vendor.helper.plist")
        try Data("x".utf8).write(to: src)
        try fm.createSymbolicLink(at: trash.appendingPathComponent(src.lastPathComponent), withDestinationURL: victim)
        let cmd = try ActionExecutor.adminDeleteCommand(src, mode: .trash, rootTrash: real.appendingPathComponent("zone").path)
        #expect(!cmd.contains { $0.contains(".Trash") })
        #expect(runAdmin(cmd).ok)
        #expect(try fm.contentsOfDirectory(atPath: victim.path).isEmpty)
    }

    /// V2-C3: the parent is replaced by a symlink between the check and the root command: nothing is touched.
    @Test func adminCommandsRefuseAParentSwappedForASymlink() throws {
        let caches = real.appendingPathComponent("Caches")
        let target = real.appendingPathComponent("opt")
        try fm.createDirectory(at: caches.appendingPathComponent("Homebrew"), withIntermediateDirectories: true)
        try fm.createDirectory(at: target.appendingPathComponent("Homebrew"), withIntermediateDirectories: true)
        let item = caches.appendingPathComponent("Homebrew")
        let zone = real.appendingPathComponent("zone").path
        let delete = try ActionExecutor.adminDeleteCommand(item, mode: .permanent)
        let trash = try ActionExecutor.adminDeleteCommand(item, mode: .trash, rootTrash: zone)
        try fm.moveItem(at: caches, to: real.appendingPathComponent("moved"))
        try fm.createSymbolicLink(at: caches, withDestinationURL: target)
        let r1 = runAdmin(delete), r2 = runAdmin(trash)
        #expect(r1.status == 3 && r2.status == 3)
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Homebrew").path))
        // And once the link is there, the command is not even built.
        #expect(throws: RemovalError.self) { try ActionExecutor.adminDeleteCommand(item, mode: .permanent) }
    }

    @Test func adminCommandsFailWhenNothingMoved() throws {
        let gone = real.appendingPathComponent("gone")
        #expect(!runAdmin(try ActionExecutor.adminDeleteCommand(gone, mode: .trash, rootTrash: real.appendingPathComponent("z").path)).ok)
        // A holding area that is a symlink is refused.
        let src = real.appendingPathComponent("f")
        try Data().write(to: src)
        try fm.createSymbolicLink(at: real.appendingPathComponent("zl"), withDestinationURL: real.appendingPathComponent("elsewhere"))
        try fm.createDirectory(at: real.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        #expect(!runAdmin(try ActionExecutor.adminDeleteCommand(src, mode: .trash, rootTrash: real.appendingPathComponent("zl").path)).ok)
        #expect(fm.fileExists(atPath: src.path))
    }

    @Test func adminPermanentDeleteEndsOptionsAndRemoves() throws {
        let weird = real.appendingPathComponent("-rf weird")
        try fm.createDirectory(at: weird.appendingPathComponent("x"), withIntermediateDirectories: true)
        let cmd = try ActionExecutor.adminDeleteCommand(weird, mode: .permanent)
        #expect(cmd[0...1] == ["/bin/sh", "-c"] && cmd[3...] == ["sh", weird.path, real.path])
        #expect(runAdmin(cmd).ok)
        #expect(!fm.fileExists(atPath: weird.path))
    }

    @Test func physicalParentAcceptsOnlyThePrivateAlias() throws {
        #expect(ActionExecutor.physicalParent(URL(fileURLWithPath: "/tmp/x")) == "/private/tmp")
        #expect(ActionExecutor.physicalParent(URL(fileURLWithPath: "/Library/Caches/x")) == "/Library/Caches")
        let link = real.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ActionExecutor.physicalParent(link.appendingPathComponent("x")) == nil)
    }

    // MARK: Admin batch script (built, then run without privileges through /bin/sh on harmless tools)

    static let nasty = ["a b", "l'été", "\"dq\"", "$HOME", "`id`", "$(/usr/bin/false)", "back\\slash", "new\nline", "-n", ""]

    @Test func adminBatchScriptQuotesEveryArgumentAndReportsFailedIndexes() throws {
        let marker = tmp.appendingPathComponent("injected")
        var commands = Self.nasty.map { ["/bin/test", $0, "=", $0] }
        commands.append(["/usr/bin/false"])
        commands.append(["/bin/test", "x'; /usr/bin/touch '\(marker.path)'; echo '", "=", "y"])
        let script = Shell.adminBatchScript(commands)
        let r = Shell.run("/bin/sh", ["-c", script])
        let failed = r.stdout.split(whereSeparator: \.isNewline).map(String.init)
        #expect(failed == ["VCFAIL:\(Self.nasty.count)", "VCFAIL:\(Self.nasty.count + 1)"])
        #expect(!fm.fileExists(atPath: marker.path))
    }

    @Test func appleScriptStringEscapesQuotesAndBackslashes() {
        #expect(Shell.appleScriptString(#"a "b" \c"#) == #""a \"b\" \\c""#)
        #expect(Shell.shellQuote("it's") == #"'it'\''s'"#)
        #expect(Shell.shellQuote("") == "''")
    }

    // MARK: launchd remove script (launchctl replaced by /usr/bin/true)

    func runRemove(_ plist: URL, zone: URL) -> ShellResult {
        guard case .command(let exe, let args, true) = PerformanceModule.removeCommand(plist: plist, domain: "system", rootTrash: zone.path)
        else { return ShellResult(status: -1, stdout: "", stderr: "") }
        return runAdmin([exe] + args, replacing: "/bin/launchctl")
    }

    @Test func removeScriptMovesThePlistIntoTheRootTrash() throws {
        let zone = real.appendingPathComponent("zone")
        let src = real.appendingPathComponent("com.x y.plist")
        try Data("new".utf8).write(to: src)
        #expect(runRemove(src, zone: zone).ok)
        #expect(!fm.fileExists(atPath: src.path))
        let dirs = try fm.contentsOfDirectory(atPath: zone.path)
        #expect(dirs.count == 1)
        #expect(try fm.contentsOfDirectory(atPath: zone.appendingPathComponent(dirs[0]).path) == [src.lastPathComponent])
    }

    /// A job removed twice (reinstalled in between): each removal gets its own folder, so neither is lost
    /// and the second really moves the plist (the old `mv -n` reported success and left it in place).
    @Test func removeScriptHandlesTheSameNameTwice() throws {
        let zone = real.appendingPathComponent("zone")
        let src = real.appendingPathComponent("com.x.plist")
        try Data("old".utf8).write(to: src)
        #expect(runRemove(src, zone: zone).ok)
        try Data("new".utf8).write(to: src)
        #expect(runRemove(src, zone: zone).ok)
        #expect(!fm.fileExists(atPath: src.path))
        #expect(try fm.contentsOfDirectory(atPath: zone.path).count == 2)
    }

    @Test func disableScriptsRefuseAppleLabels() {
        for script in [PerformanceModule.disableScript, PerformanceModule.enableScript] {
            let s = script.replacingOccurrences(of: "/bin/launchctl", with: "/usr/bin/true")
            #expect(Shell.run("/bin/sh", ["-c", s, "sh", "system", "/x.plist", "com.apple.foo"]).status == 2)
            #expect(Shell.run("/bin/sh", ["-c", s, "sh", "system", "/x.plist", "dev.vc.job"]).ok)
        }
    }
}
