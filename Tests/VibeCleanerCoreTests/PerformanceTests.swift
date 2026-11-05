import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct PerformanceTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writePlist(_ dict: [String: Any], _ name: String, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        return url
    }

    @Test func parsesLaunchPlistAndDetectsBrokenProgram() throws {
        let dir = root.appendingPathComponent("LaunchAgents")
        let ok = try writePlist(["Label": "dev.vc.ok", "ProgramArguments": ["/bin/ls", "-l"], "RunAtLoad": true], "ok.plist", in: dir)
        let broken = try writePlist(["Label": "dev.vc.broken", "Program": root.appendingPathComponent("gone").path,
                                     "StartInterval": 60], "broken.plist", in: dir)
        let a = try #require(LaunchItem.parse(ok, scope: .userAgent))
        #expect(a.label == "dev.vc.ok" && a.program == "/bin/ls" && a.runAtLoad && !a.isBroken)
        let b = try #require(LaunchItem.parse(broken, scope: .userAgent))
        #expect(b.isBroken && b.periodic)
        let empty = try #require(LaunchItem.parse(try writePlist([:], "empty.plist", in: dir), scope: .userAgent))
        // No program is not broken: launchd never runs it (lot C).
        #expect(!empty.isBroken && empty.label == "empty")
        let bundled = try writePlist(["Label": "dev.vc.b", "BundleProgram": "Contents/MacOS/x"], "b.plist", in: dir)
        #expect(LaunchItem.parse(bundled, scope: .userAgent)?.isBroken == false)
    }

    @Test func skipsAppleAndHandlesUnreadable() throws {
        let dir = root.appendingPathComponent("LaunchAgents")
        let apple = try writePlist(["Label": "com.apple.thing", "Program": "/bin/ls"], "x.plist", in: dir)
        #expect(LaunchItem.parse(apple, scope: .userAgent) == nil)
        let junk = dir.appendingPathComponent("junk.plist")
        try Data("not a plist".utf8).write(to: junk)
        let j = try #require(LaunchItem.parse(junk, scope: .userAgent))
        #expect(!j.readable && j.label == "junk" && !j.isBroken)
    }

    @Test func buildsLaunchGroupWithActions() throws {
        let user = root.appendingPathComponent("user"), daemons = root.appendingPathComponent("daemons")
        _ = try writePlist(["Label": "dev.vc.ok", "Program": "/bin/ls"], "ok.plist", in: user)
        _ = try writePlist(["Label": "dev.vc.broken", "Program": "/nonexistent/vc-tool"], "broken.plist", in: user)
        let d = try writePlist(["Label": "dev.vc.daemon", "Program": "/bin/ls"], "d.plist", in: daemons)
        _ = try writePlist(["Label": "com.apple.ignored"], "com.apple.ignored.plist", in: daemons)

        let ctx = ModuleContext(home: root)
        let group = PerformanceModule.launchGroup(roots: [(user, .userAgent), (daemons, .daemon)], context: ctx, uid: 501)
        let toggles: Set<String> = ["performance.launchd.disable", "performance.launchd.enable"]
        let items = group.groups.filter { !toggles.contains($0.id) }.flatMap(\.allItems)
        #expect(group.groups.first { $0.id == "performance.launchd.disable" }?.items.count == 2)
        #expect(items.map(\.name).sorted() == ["dev.vc.broken", "dev.vc.daemon", "dev.vc.ok"])
        #expect(group.defaultSelection == ["performance.launchd.\(user.appendingPathComponent("broken.plist").path)"])

        let ok = try #require(items.first { $0.name == "dev.vc.ok" })
        #expect(ok.action == .custom(PerformanceModule.Key.removeUserAgent))
        #expect(ok.detail?.contains("Apple") == true)
        let daemon = try #require(items.first { $0.name == "dev.vc.daemon" })
        #expect(daemon.action == PerformanceModule.removeCommand(plist: d, domain: "system"))
    }

    @Test func honoursExclusions() throws {
        let user = root.appendingPathComponent("user")
        _ = try writePlist(["Label": "dev.vc.keep", "Program": "/nonexistent"], "keep.plist", in: user)
        let ctx = ModuleContext(exclusions: [user.path], home: root)
        #expect(PerformanceModule.launchGroup(roots: [(user, .userAgent)], context: ctx).isEmpty)
    }

    @Test func maintenanceTasksFollowEnvironment() throws {
        let index = root.appendingPathComponent("Library/Mail/V10/MailData/Envelope Index")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: index)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Mail/V9"), withIntermediateDirectories: true)

        var env = PerformanceModule.MaintenanceEnvironment(home: root, snapshots: 0, mailRunning: false, freeRatio: 0.5,
                                                           fileExists: { $0 == "/usr/sbin/purge" }, uid: 501)
        func flat(_ e: PerformanceModule.MaintenanceEnvironment) -> ResultGroup {
            ResultGroup(id: "all", title: "", groups: PerformanceModule.maintenanceGroups(e))
        }
        var g = flat(env)
        let ids = Set(g.allItems.map(\.id))
        #expect(ids == ["performance.task.freeRAM", "performance.task.flushDNS", "performance.task.speedUpMail",
                        "performance.task.reindexSpotlight", "performance.task.resetPermissions"])
        #expect(!g.defaultSelection.contains("performance.task.reindexSpotlight"))
        #expect(g.defaultSelection.contains("performance.task.speedUpMail"))
        #expect(g.allItems.first { $0.id == "performance.task.speedUpMail" }?.url == index)
        #expect(g.allItems.first { $0.id == "performance.task.resetPermissions" }?.action
                == .command(executable: "/usr/sbin/diskutil", arguments: ["resetUserPermissions", "/", "501"], admin: true))

        env.snapshots = 2; env.freeRatio = 0.05; env.mailRunning = true
        env.fileExists = { _ in true }
        g = flat(env)
        #expect(g.defaultSelection.contains("performance.task.thinSnapshots"))
        #expect(!g.defaultSelection.contains("performance.task.speedUpMail"))
        #expect(g.allItems.contains { $0.id == "performance.task.periodic" })

        // Vibe Check: password tasks stay listed but unchecked.
        env.autoSelectsPasswordTasks = false
        g = flat(env)
        #expect(g.allItems.contains { $0.id == "performance.task.freeRAM" })
        #expect(g.defaultSelection.isDisjoint(with: ["performance.task.freeRAM", "performance.task.flushDNS"]))
    }

    @Test func ramAndTimeMachineHaveTheirOwnTiles() {
        let env = PerformanceModule.MaintenanceEnvironment(home: root, snapshots: 1, mailRunning: false, freeRatio: 0.5,
                                                           fileExists: { _ in true }, uid: 501)
        let groups = PerformanceModule.maintenanceGroups(env)
        #expect(groups.map(\.id) == ["performance.maintenance", "performance.ram", "performance.timeMachine"])
        #expect(groups[1].items.map(\.id) == ["performance.task.freeRAM"])
        #expect(groups[2].items.map(\.id) == ["performance.task.thinSnapshots"])
        #expect(!groups[0].items.contains { $0.id == "performance.task.freeRAM" || $0.id == "performance.task.thinSnapshots" })
    }

    @Test func harmlessMaintenanceIsNotMarkedIrreversible() {
        let env = PerformanceModule.MaintenanceEnvironment(home: root, snapshots: 1, mailRunning: false, freeRatio: 0.5,
                                                           fileExists: { _ in true }, uid: 501)
        let items = Dictionary(uniqueKeysWithValues: PerformanceModule.maintenanceGroups(env).flatMap(\.allItems).map { ($0.id, $0) })
        for key in ["freeRAM", "flushDNS", "reindexSpotlight", "periodic"] {
            #expect(items["performance.task.\(key)"]?.isIrreversible == false, "\(key)")
        }
        for key in ["thinSnapshots", "resetPermissions"] { #expect(items["performance.task.\(key)"]?.isIrreversible == true, "\(key)") }
    }

    @Test func settingsLinksAreButtonsNotChoices() {
        let link = ResultItem(id: "x.settings", name: "Gérer", action: .command(executable: "/usr/bin/open",
                              arguments: ["x-apple.systempreferences:com.apple.wifi-settings-extension"], admin: false))
        #expect(link.openLink?.absoluteString == "x-apple.systempreferences:com.apple.wifi-settings-extension")
        #expect(!link.isActionable)
        let g = ResultGroup(id: "g", title: "", items: [link, ResultItem(id: "a", name: "a", action: .custom("k"))])
        #expect(g.bulkItems.map(\.id) == ["a"])
    }

    @Test func weeklyMaintenanceFollowsLastRunDates() {
        let now = Date()
        let day: TimeInterval = 86_400
        var env = PerformanceModule.MaintenanceEnvironment(home: root, snapshots: 0, mailRunning: false, freeRatio: 0.5,
                                                           fileExists: { _ in true }, now: now, uid: 501)
        env.lastRuns = ["flushDNS": now.addingTimeInterval(-2 * day), "freeRAM": now.addingTimeInterval(-8 * day),
                        "reindexSpotlight": now.addingTimeInterval(-31 * day)]
        let sel = ResultGroup(id: "all", title: "", groups: PerformanceModule.maintenanceGroups(env)).defaultSelection
        #expect(!sel.contains("performance.task.flushDNS"))
        #expect(sel.contains("performance.task.freeRAM"))
        #expect(sel.contains("performance.task.reindexSpotlight"))
        let flush = PerformanceModule.maintenanceGroups(env)[0].items.first { $0.id == "performance.task.flushDNS" }
        #expect(flush?.detail?.contains("Dernière exécution") == true)

        // Never run: reindexing is not recommended on a first scan.
        env.lastRuns = [:]
        let first = ResultGroup(id: "all", title: "", groups: PerformanceModule.maintenanceGroups(env)).defaultSelection
        #expect(first.contains("performance.task.flushDNS") && !first.contains("performance.task.reindexSpotlight"))
        #expect(env.due("x", days: 7))
    }

    @Test func historyRecordsDatesInItsOwnSuite() throws {
        let suite = "vc-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let h = MaintenanceHistory(suiteName: suite)
        #expect(h.lastRuns.isEmpty)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        h.record(["flushDNS", "freeRAM"], at: date)
        #expect(h.lastRuns == ["flushDNS": date, "freeRAM": date])
        h.setLoginItem("/Applications/Foo.app", disabled: true)
        h.setLoginItem("/Applications/Bar.app", disabled: true)
        h.setLoginItem("/Applications/Foo.app", disabled: false)
        #expect(h.disabledLoginItems == ["/Applications/Bar.app"])
        #expect(UserDefaults.standard.dictionary(forKey: MaintenanceHistory.lastRunKey)?["flushDNS"] as? Double != date.timeIntervalSince1970)
    }

    @Test func dryRunRecordsNoHistory() async throws {
        let suite = "vc-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let item = ResultItem(id: "performance.task.flushDNS", name: "DNS",
                              action: .command(executable: "/usr/bin/true", arguments: [], admin: true))
        let m = PerformanceModule(history: MaintenanceHistory(suiteName: suite))
        let report = await m.execute([item], context: ModuleContext(dryRun: true, home: root))
        #expect(report.processed == ["performance.task.flushDNS"])
        #expect(m.history.lastRuns.isEmpty)
    }

    @Test func speedUpMailBacksUpBeforeVacuum() throws {
        let index = root.appendingPathComponent("Mail/V10/MailData/Envelope Index")
        var steps: [String] = []
        try PerformanceModule.speedUpMail(index, mailRunning: false,
                                          backUp: { steps.append("backup \($0.lastPathComponent)") },
                                          sqlite: { steps.append("vacuum \($0.lastPathComponent)"); return ShellResult(status: 0, stdout: "", stderr: "") },
                                          reimport: { steps.append("mdimport \($0.lastPathComponent)") })
        #expect(steps == ["backup Envelope Index", "vacuum Envelope Index", "mdimport V10"])

        steps = []
        #expect(throws: (any Error).self) {
            try PerformanceModule.speedUpMail(index, mailRunning: false, backUp: { _ in throw RemovalError.failed("x", "y") },
                                              sqlite: { _ in steps.append("vacuum"); return ShellResult(status: 0, stdout: "", stderr: "") },
                                              reimport: { _ in steps.append("mdimport") })
        }
        #expect(steps.isEmpty)
        #expect(throws: (any Error).self) {
            try PerformanceModule.speedUpMail(index, mailRunning: true, backUp: { _ in steps.append("backup") })
        }
        #expect(steps.isEmpty)
    }

    @Test func parsesTimeMachineSnapshots() {
        let out = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-10-19-101112.local
        com.apple.os.update-ABCDEF
        com.apple.TimeMachine.2026-10-20-090000.local
        """
        #expect(PerformanceModule.timeMachineSnapshots(in: out).count == 2)
    }

    @Test func loginGroupNeverAutoSelects() {
        let g = PerformanceModule.loginGroup([.init(name: "Ghost", url: root.appendingPathComponent("Ghost.app")),
                                              .init(name: "Ls", url: URL(fileURLWithPath: "/bin/ls"))])
        // The installed one is only under "Désactiver" (lot C).
        #expect(g.items.count == 1 && g.defaultSelection.isEmpty)
        #expect(g.items[0].detail?.hasPrefix("Introuvable") == true)
    }

    @Test func loginItemsCanBeDisabledAndReenabled() {
        let gone = root.appendingPathComponent("Gone.app").path
        let g = PerformanceModule.loginGroup([.init(name: "Ghost", url: root.appendingPathComponent("Ghost.app")),
                                              .init(name: "Ls", url: URL(fileURLWithPath: "/bin/ls"))],
                                             disabled: ["/bin/ls", gone]).pruned()
        #expect(g.defaultSelection.isEmpty)
        let disable = g.groups.first { $0.id == "performance.login.disable" }
        #expect(disable?.items.map(\.id) == ["performance.login.disable./bin/ls"])
        #expect(disable?.items.first?.action == .custom(PerformanceModule.Key.disableLoginItem))
        // Still listed by macOS: no "Réactiver" row for it.
        let enable = g.groups.first { $0.id == "performance.login.enable" }
        #expect(enable?.items.map(\.id) == ["performance.login.enable.\(gone)"])
        #expect(enable?.items.first?.action == .custom(PerformanceModule.Key.enableLoginItem))
        #expect(enable?.items.first?.name == "Gone")
        #expect(Set(g.allItems.map(\.id)).count == g.allItems.count)
    }

    @Test func parsesLaunchctlPrint() {
        let out = """
        gui/501 = {
        \ttype = login
        \tservices = {
        \t\t   35143   (pe) \tcom.example.running
        \t\t       0      - \tcom.example.idle
        \t}
        \tendpoints = {
        \t\t"com.example.x" = {
        \t\t\tport = 0x1
        \t\t}
        \t}
        \tdisabled services = {
        \t\t"com.example.off" => disabled
        \t\t"com.example.on" => enabled
        \t}
        }
        """
        let s = LaunchdStatus.parse(out)
        #expect(s.loaded == ["com.example.running": 35143, "com.example.idle": 0])
        #expect(s.disabled == ["com.example.off"])
    }

    @Test func launchGroupShowsStatusAndToggles() throws {
        let user = root.appendingPathComponent("user"), daemons = root.appendingPathComponent("daemons")
        let run = try writePlist(["Label": "com.example.running", "Program": "/bin/ls"], "run.plist", in: user)
        let off = try writePlist(["Label": "com.example.off", "Program": "/bin/ls"], "off.plist", in: user)
        _ = try writePlist(["Label": "com.example.broken", "Program": "/nonexistent/vc"], "broken.plist", in: user)
        let d = try writePlist(["Label": "com.example.daemon", "Program": "/bin/ls"], "d.plist", in: daemons)
        let status = ["gui/501": LaunchdStatus(loaded: ["com.example.running": 42], disabled: ["com.example.off"]),
                      "system": LaunchdStatus(loaded: ["com.example.daemon": 0])]
        let g = PerformanceModule.launchGroup(roots: [(user, .userAgent), (daemons, .daemon)], context: ModuleContext(home: root),
                                              uid: 501, status: status)
        let byId = Dictionary(uniqueKeysWithValues: g.allItems.map { ($0.id, $0) })
        #expect(byId["performance.launchd.\(run.path)"]?.detail?.contains("en cours (PID 42)") == true)
        #expect(byId["performance.launchd.\(off.path)"]?.detail?.contains("non chargé") == true)
        #expect(byId["performance.launchd.\(off.path)"]?.detail?.contains("désactivé dans launchd") == true)
        #expect(byId["performance.launchd.\(d.path)"]?.detail?.contains("chargé") == true)

        let disable = try #require(g.groups.first { $0.id == "performance.launchd.disable" })
        #expect(Set(disable.items.map(\.name)) == ["com.example.running", "com.example.daemon"])
        #expect(byId["performance.launchd.disable.\(run.path)"]?.action == .command(
            executable: "/bin/sh", arguments: ["-c", PerformanceModule.disableScript, "sh", "gui/501", run.path, "com.example.running"], admin: false))
        #expect(byId["performance.launchd.disable.\(d.path)"]?.action == .command(
            executable: "/bin/sh", arguments: ["-c", PerformanceModule.disableScript, "sh", "system", d.path, "com.example.daemon"], admin: true))
        let enable = try #require(g.groups.first { $0.id == "performance.launchd.enable" })
        #expect(enable.items.map(\.id) == ["performance.launchd.enable.\(off.path)"])
        #expect(byId["performance.launchd.enable.\(off.path)"]?.action == .command(
            executable: "/bin/sh", arguments: ["-c", PerformanceModule.enableScript, "sh", "gui/501", off.path, "com.example.off"], admin: false))
        // Toggles are never selected; only the broken agent is.
        #expect(g.defaultSelection == ["performance.launchd.\(user.appendingPathComponent("broken.plist").path)"])
    }

    @Test func dryRunRemovesNothing() async throws {
        let user = root.appendingPathComponent("user")
        let plist = try writePlist(["Label": "dev.vc.x", "Program": "/nonexistent"], "x.plist", in: user)
        let ctx = ModuleContext(dryRun: true, home: root)
        let items = PerformanceModule.launchGroup(roots: [(user, .userAgent)], context: ctx).allItems
        let report = await PerformanceModule().execute(items, context: ctx)
        #expect(report.processed.count == 1)
        #expect(FileManager.default.fileExists(atPath: plist.path))
    }
}
