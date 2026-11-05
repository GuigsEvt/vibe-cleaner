import Foundation
import Testing
@testable import VibeCleanerCore

/// Parsers of command outputs and pure decision logic (alerts, guide, Radar tree), on
/// empty, truncated and unusual inputs. No command is run.
@Suite struct ParsersEdgeTests {
    let fm = FileManager.default

    // MARK: FileScan

    @Test func yaraLinesWithSpacesBlanksAndCRLF() {
        let out = "Rule_A /Users/x/My Folder/évil file.sh\r\n\nlonely\n  \nRule_B /a\n"
        let hits = FileScan.parseYARA(out)
        #expect(hits.map(\.rule) == ["Rule_A", "Rule_B"])
        #expect(hits.first?.path == "/Users/x/My Folder/évil file.sh")
        #expect(FileScan.parseYARA("").isEmpty)
    }

    @Test func zipTotalsEdges() {
        #expect(FileScan.zipTotals("") == nil)
        #expect(FileScan.zipTotals("1 file, 0 bytes uncompressed, 0 bytes compressed:  0.0%").map { [$0.files, Int($0.uncompressed), Int($0.compressed)] } == [1, 0, 0])
        #expect(FileScan.zipTotals("zipinfo:  cannot find or open x") == nil)
        // A stored (empty) file: compressed 0 must not divide or allow an infinite ratio.
        #expect(FileScan.zipIsSafe((files: 1, uncompressed: 0, compressed: 0)))
        #expect(!FileScan.zipIsSafe((files: 1, uncompressed: 101, compressed: 0)))
        #expect(FileScan.zipIsSafe((files: 10_000, uncompressed: 1 << 30, compressed: 1 << 30)))
        #expect(!FileScan.zipIsSafe((files: 10_001, uncompressed: 1, compressed: 1)))
        #expect(!FileScan.zipIsSafe((files: 1, uncompressed: (1 << 30) + 1, compressed: 1 << 30)))
    }

    @Test func candidatesSkipSymlinksBigFilesAndRespectDepth() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("vc-fs-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("a/b/c/d"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("top.sh"))
        try Data("x".utf8).write(to: root.appendingPathComponent("a/b/c/d/deep.sh"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link.sh").path, withDestinationPath: root.appendingPathComponent("top.sh").path)
        let big = root.appendingPathComponent("big.zip")
        fm.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(FileScan.maxHashedSize + 1)) // sparse, nothing written
        try h.close()
        let all = Set(FileScan.candidates(under: root).map(\.lastPathComponent))
        #expect(all == ["top.sh", "deep.sh"])
        let shallow = Set(FileScan.candidates(under: root, maxLevel: 2).map(\.lastPathComponent))
        #expect(shallow == ["top.sh"])
        #expect(FileScan.candidates(under: root.appendingPathComponent("absent")).isEmpty)
        #expect(FileScan.candidates(under: root.appendingPathComponent("top.sh")).map(\.lastPathComponent) == ["top.sh"])
        #expect(FileScan.candidates(under: root.appendingPathComponent("notes.txt")).isEmpty)
    }

    @Test func hashListParsing() {
        let h = String(repeating: "a", count: 64)
        let list = HashList(text: "\(h.uppercased())\tMACOS_X  # comment\r\n# full comment\n\(String(repeating: "b", count: 63)) short\nzz\(String(repeating: "c", count: 62)) nothex\n\(String(repeating: "d", count: 64))\n")
        #expect(list.names == [h: "MACOS_X", String(repeating: "d", count: 64): "Liste de hash locale"])
        #expect(HashList(text: "").isEmpty)
    }

    // MARK: launchctl / tmutil

    @Test func launchdStatusEdges() {
        let out = """
        gui/501 = {
        \tservices = {
        \t\t     0      0 \tcom.foo.idle
        \t\t  1234      0 \tcom.foo.running
        \t\t     -      0 \tcom.foo.dash
        \t\tgarbage
        \t\t    12    -9 \tcom.with space.label
        \t}
        \tdisabled services = {
        \t\t"com.foo.off" => disabled
        \t\t"com.foo.on" => enabled
        \t\t"broken =>
        \t}
        }
        """
        let s = LaunchdStatus.parse(out)
        #expect(s.loaded == ["com.foo.idle": 0, "com.foo.running": 1234, "com.with space.label": 12])
        #expect(s.disabled == ["com.foo.off"])
        #expect(LaunchdStatus.parse("") == LaunchdStatus())
    }

    @Test func timeMachineSnapshotsEdges() {
        #expect(PerformanceModule.timeMachineSnapshots(in: "").isEmpty)
        #expect(PerformanceModule.timeMachineSnapshots(in: "Snapshots for disk /:\r\n  com.apple.TimeMachine.2026-10-01-120000.local\r\nnot one\n") ==
                ["com.apple.TimeMachine.2026-10-01-120000.local"])
    }

    // MARK: Radar tree

    func tree() -> (root: SpaceNode, a: SpaceNode, b: SpaceNode, f: SpaceNode) {
        let f = SpaceNode(name: "f", size: 30, fileCount: 1, isDirectory: false)
        let g = SpaceNode(name: "g", size: 5, fileCount: 1, isDirectory: false)
        let a = SpaceNode(name: "a", size: 35, fileCount: 2, isDirectory: true, children: [f, g])
        let b = SpaceNode(name: "b", size: 20, fileCount: 1, isDirectory: true, children: [SpaceNode(name: "h", size: 20, fileCount: 1, isDirectory: false)])
        let root = SpaceNode(name: "r", size: 55, fileCount: 3, isDirectory: true, children: [b, a], rootURL: URL(fileURLWithPath: "/tmp/r"))
        return (root, a, b, f)
    }

    @Test func detachEdges() {
        let t = tree()
        t.root.detach() // no parent: no-op
        #expect(t.root.size == 55)
        t.f.detach()
        t.f.detach() // twice: no double subtraction
        #expect(t.a.size == 5 && t.root.size == 25 && t.root.fileCount == 2)
        #expect(t.root.children.map(\.name) == ["b", "a"]) // re-sorted: b (20) now ahead of a (5)
        #expect(t.root.node(at: "/tmp/r/a/f") == nil)
        #expect(t.root.nearest(to: "/tmp/r/a/f") === t.a)
        #expect(t.root.nearest(to: "/elsewhere") === t.root)
    }

    @Test func outermostEdges() {
        #expect(SpaceNode.outermost([]) == [])
        #expect(SpaceNode.outermost(["/a/b", "/a/bc", "/a/b/c"]) == ["/a/b", "/a/bc"])
        #expect(SpaceNode.outermost(["/", "/x"]) == ["/"])
        #expect(SpaceNode.outermost(["/a/", "/a/b"]) == ["/a/"])
    }

    @Test func protectedRadarPaths() {
        let home = "/Users/x"
        // Lot B: the roots SafeRemover protects (~/Library/Caches…) are protected in Radar too.
        for p in ["/private/var/folders/zz", "/var", "/etc/hosts", home, "\(home)/Library", "\(home)/Library/CloudStorage",
                  "\(home)/Library/CloudStorage/GoogleDrive-a@b.c", "\(home)/Library/Caches"] {
            #expect(SpaceNode.isProtected(path: p, home: home), "\(p)")
        }
        for p in ["\(home)/Library/Caches/com.example", "\(home)/Library/CloudStorage/GoogleDrive-a@b.c/file", "/Applications/Foo.app", "/Systemx"] {
            #expect(!SpaceNode.isProtected(path: p, home: home), "\(p)")
        }
    }

    // MARK: Alerts

    let gb: Int64 = 1_000_000_000
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func snapshot(free: Int64 = 200_000_000_000, trash: Int64? = 1) -> SystemSnapshot {
        SystemSnapshot(memory: MemoryUsage(total: 16 * gb), disk: DiskUsage(total: 500 * gb, available: free), trashSize: trash)
    }

    var fresh: AlertState {
        var s = AlertState(firstLaunch: now.addingTimeInterval(-3_600))
        s.lastVibeCheck = now
        return s
    }

    @Test func thresholdsAreStrict() {
        let settings = AlertSettings()
        let kinds = AlertPolicy.due(snapshot: snapshot(free: settings.diskThreshold, trash: settings.trashThreshold),
                                    settings: settings, state: fresh, now: now).map(\.kind)
        #expect(kinds.isEmpty)
        let below = AlertPolicy.due(snapshot: snapshot(free: settings.diskThreshold - 1, trash: settings.trashThreshold + 1),
                                    settings: settings, state: fresh, now: now).map(\.kind)
        #expect(below == [.lowDisk, .trashFull])
    }

    @Test func unknownReadingsRaiseNothing() {
        let s = SystemSnapshot(memory: MemoryUsage(total: 16 * gb), disk: nil, trashSize: nil)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: fresh, now: now).isEmpty)
        let zero = SystemSnapshot(memory: MemoryUsage(), disk: DiskUsage(total: 0, available: 0))
        #expect(AlertPolicy.due(snapshot: zero, settings: AlertSettings(), state: fresh, now: now).isEmpty)
    }

    @Test func snoozeExpiresExactlyAndForeverNever() {
        var st = fresh
        let s = snapshot(free: 1)
        st.snooze(.lowDisk, .day, now: now)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: st, now: now.addingTimeInterval(86_399)).isEmpty)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: st, now: now.addingTimeInterval(86_400)).map(\.kind).contains(.lowDisk))
        st.snooze(.lowDisk, .forever, now: now)
        #expect(st.isSnoozed(.lowDisk, now: now.addingTimeInterval(1e9)))
    }

    @Test func cooldownBoundary() {
        var st = fresh
        let a = Alert(kind: .lowDisk, title: "", body: "", module: "junk")
        st.markSent(a, now: now)
        let s = snapshot(free: 1)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: st, now: now.addingTimeInterval(AlertPolicy.cooldown - 1)).isEmpty)
        #expect(!AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: st, now: now.addingTimeInterval(AlertPolicy.cooldown)).isEmpty)
    }

    @Test func trashedAppsBookkeeping() throws {
        let app = { (p: String) in TrashWatch.App(url: URL(fileURLWithPath: p), name: (p as NSString).lastPathComponent, bundleID: "b", leftovers: []) }
        var st = fresh
        let first = AlertInputs(trashedApps: [app("/T/A.app")])
        // First look: records, does not alert.
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: st, inputs: first, now: now).isEmpty)
        st.prune(first)
        #expect(st.trashedAppsSeen == ["/T/A.app"])
        let second = AlertInputs(trashedApps: [app("/T/A.app"), app("/T/B.app"), app("/T/C.app")])
        let alert = try #require(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: st, inputs: second, now: now).first)
        #expect(alert.subjects == ["/T/B.app", "/T/C.app"])
        #expect(alert.body.hasPrefix("B.app, C.app sont"))
        st.markSent(alert, now: now)
        // Emptied Trash: forgotten, so the same app trashed again alerts again.
        st.prune(AlertInputs())
        #expect(st.trashedAppsSeen == [])
    }

    @Test func accessoryBatteryEdges() {
        var st = fresh
        let low = AlertInputs(accessories: [PeripheralBattery(id: "m", name: "Souris", percent: 19), PeripheralBattery(id: "k", name: "Clavier", percent: 20)])
        let alerts = AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: st, inputs: low, now: now)
        #expect(alerts.map(\.subjects) == [["m"]]) // 20 % is not low
        st.markSent(alerts[0], now: now)
        st.lastSent = [:] // isolate the per-accessory postponement from the hourly cooldown
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: st, inputs: low, now: now.addingTimeInterval(3_600 * 23)).isEmpty)
        #expect(!AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: st, inputs: low, now: now.addingTimeInterval(86_400)).isEmpty)
    }

    @Test func reminderWithAClockThatWentBack() {
        var st = AlertState(firstLaunch: now.addingTimeInterval(86_400 * 30)) // first launch "in the future"
        st.lastVibeCheck = nil
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: st, now: now).isEmpty)
    }

    @Test func defaultDiskThresholdEdges() {
        #expect(AlertSettings.defaultDiskThreshold(capacity: nil) == 100 * gb)
        #expect(AlertSettings.defaultDiskThreshold(capacity: 0) == 100 * gb)
        #expect(AlertSettings.defaultDiskThreshold(capacity: -5) == 100 * gb)
        #expect(AlertSettings.defaultDiskThreshold(capacity: 1) == 2 * gb)
        #expect(AlertSettings.defaultDiskThreshold(capacity: 100_000 * gb) == 100 * gb)
    }

    @Test func oldStateWithoutOptionalFieldsDecodes() throws {
        let json = #"{"snoozedUntil":[],"lastSent":[],"firstLaunch":0}"#
        let st = try JSONDecoder().decode(AlertState.self, from: Data(json.utf8))
        #expect(st.accessoriesNotified == nil && st.trashedAppsSeen == nil && st.lastVibeCheck == nil)
    }

    // MARK: Guide

    func issue(_ id: String, _ severity: IssueSeverity, priority: Int = 0) -> HealthIssue {
        HealthIssue(id: id, title: id, detail: "", severity: severity, penalty: 1, priority: priority, module: nil)
    }

    @Test func guideEdges() {
        #expect(Guide.badge([]) == nil)
        #expect(Guide.badge([issue("i", .info)]) == nil)
        let b = Guide.badge([issue("w", .warning), issue("c", .critical), issue("i", .info)])
        #expect(b?.severity == .critical && b?.count == 2)
        let issues = [issue("a", .warning), issue("b", .info)]
        #expect(Guide.visible(issues, skipped: ["a": now], now: now).map(\.id) == ["a", "b"]) // expired exactly now
        #expect(Guide.today(issues, skipped: ["a": now.addingTimeInterval(1), "b": .distantFuture], now: now) == nil)
        #expect(Guide.sample("no_such_factor") == nil)
        #expect(Guide.explanation("whatever").isEmpty == false)
    }


    @Test func simulateReplacesInsteadOfDuplicating() {
        let base = HealthAssessment(issues: [issue("low_ram", .info), issue("other", .info)])
        let sim = Guide.simulate(base, forcing: ["low_ram", "unknown"])
        #expect(sim.issues.filter { $0.id == "low_ram" }.count == 1)
        #expect(sim.issues.contains { $0.id == "other" })
        #expect(!sim.issues.contains { $0.id == "unknown" })
    }
}
