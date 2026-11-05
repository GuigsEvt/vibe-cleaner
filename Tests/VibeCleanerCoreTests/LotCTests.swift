import Foundation
import SQLite3
import Testing
@testable import VibeCleanerCore

/// Lot C: launchd and login items (Performance), persistence heuristics, privacy groups and quarantine (Protection).
/// Everything happens in a temporary folder; no test runs launchctl or any other system command.
@Suite struct LotCTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-lotc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func writePlist(_ dict: [String: Any], _ name: String, in dir: URL) throws -> URL {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
        return url
    }

    func write(_ text: String, _ rel: String) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: 1. A plist without a program is not broken

    @Test func plistWithoutProgramIsNotBroken() throws {
        let user = root.appendingPathComponent("user")
        let empty = try writePlist([:], "com.google.keystone.agent.plist", in: user)
        let labelOnly = try writePlist(["Label": "com.amazon.aws.ssm.SessionManagerPlugin"], "ssm.plist", in: user)
        #expect(LaunchItem.parse(empty, scope: .userAgent)?.isBroken == false)
        #expect(LaunchItem.parse(labelOnly, scope: .userAgent)?.isBroken == false)

        let g = PerformanceModule.launchGroup(roots: [(user, .userAgent)], context: ModuleContext(home: root), uid: 501)
        #expect(g.defaultSelection.isEmpty)
        let rows = g.allItems.filter { $0.id == "performance.launchd.\(labelOnly.path)" || $0.id == "performance.launchd.\(empty.path)" }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.detail?.contains("Cassé") != true && $0.symbol != "exclamationmark.triangle" })
    }

    @Test func adminLaunchJobIsNeverSelectedByDefault() throws {
        let user = root.appendingPathComponent("user"), daemons = root.appendingPathComponent("daemons"),
            agents = root.appendingPathComponent("agents")
        let u = try writePlist(["Label": "dev.vc.u", "Program": "/nonexistent/vc-u"], "u.plist", in: user)
        try writePlist(["Label": "dev.vc.d", "Program": "/nonexistent/vc-d"], "d.plist", in: daemons)
        try writePlist(["Label": "dev.vc.a", "Program": "/nonexistent/vc-a"], "a.plist", in: agents)
        let g = PerformanceModule.launchGroup(roots: [(user, .userAgent), (daemons, .daemon), (agents, .globalAgent)],
                                              context: ModuleContext(home: root), uid: 501)
        #expect(g.defaultSelection == ["performance.launchd.\(u.path)"])
    }

    // MARK: 2. Toggle subgroups are ticked one by one

    @Test func toggleSubgroupsAreNotBulkSelectable() throws {
        let user = root.appendingPathComponent("user")
        try writePlist(["Label": "com.example.on", "Program": "/bin/ls"], "on.plist", in: user)
        try writePlist(["Label": "com.example.off", "Program": "/bin/ls"], "off.plist", in: user)
        let status = ["gui/501": LaunchdStatus(loaded: [:], disabled: ["com.example.off"])]
        let launch = PerformanceModule.launchGroup(roots: [(user, .userAgent)], context: ModuleContext(home: root), uid: 501, status: status)
        for id in ["performance.launchd.disable", "performance.launchd.enable"] {
            #expect(launch.groups.first { $0.id == id }?.bulkSelectable == false, "\(id)")
        }
        #expect(!launch.bulkItems.contains { $0.id.hasPrefix("performance.launchd.disable.") || $0.id.hasPrefix("performance.launchd.enable.") })

        let login = PerformanceModule.loginGroup([.init(name: "Ls", url: URL(fileURLWithPath: "/bin/ls"))],
                                                 disabled: [root.appendingPathComponent("Gone.app").path], appFolders: [])
        for id in ["performance.login.disable", "performance.login.enable"] {
            #expect(login.groups.first { $0.id == id }?.bulkSelectable == false, "\(id)")
        }
        #expect(login.bulkItems.isEmpty)
    }

    // MARK: 3. One action per target

    @Test func presentLoginItemOnlyOffersDisable() {
        let g = PerformanceModule.loginGroup([.init(name: "Google Drive", url: URL(fileURLWithPath: "/bin/ls")),
                                              .init(name: "Ghost", url: root.appendingPathComponent("Ghost.app"))], appFolders: [])
        let rows = g.allItems.filter { $0.name == "Google Drive" }
        #expect(rows.map(\.action) == [.custom(PerformanceModule.Key.disableLoginItem)])
        let ghost = g.allItems.filter { $0.name == "Ghost" }
        #expect(ghost.map(\.action) == [.custom(PerformanceModule.Key.removeLoginItem)])
        #expect(g.defaultSelection.isEmpty)
    }

    @Test func reversibleActionWinsOverRemovalOfTheSameTarget() async throws {
        let user = root.appendingPathComponent("user")
        let plist = try writePlist(["Label": "dev.vc.x", "Program": "/bin/ls"], "x.plist", in: user)
        let other = try writePlist(["Label": "dev.vc.y", "Program": "/bin/ls"], "y.plist", in: user)
        let g = PerformanceModule.launchGroup(roots: [(user, .userAgent)], context: ModuleContext(home: root), uid: 501)
        let all = g.allItems
        let remove = try #require(all.first { $0.id == "performance.launchd.\(plist.path)" })
        let disable = try #require(all.first { $0.id == "performance.launchd.disable.\(plist.path)" })
        let removeOther = try #require(all.first { $0.id == "performance.launchd.\(other.path)" })
        let loginRemove = ResultItem(id: "performance.login./Applications/Foo.app", name: "Foo", url: URL(fileURLWithPath: "/Applications/Foo.app"),
                                     action: .custom(PerformanceModule.Key.removeLoginItem))
        let loginDisable = ResultItem(id: "performance.login.disable./Applications/Foo.app", name: "Foo",
                                      url: URL(fileURLWithPath: "/Applications/Foo.app"), action: .custom(PerformanceModule.Key.disableLoginItem))

        let kept = PerformanceModule.reversibleFirst([remove, disable, removeOther, loginRemove, loginDisable])
        #expect(kept.map(\.id) == [disable.id, removeOther.id, loginDisable.id])

        let report = await PerformanceModule().execute([remove, disable], context: ModuleContext(dryRun: true, home: root))
        #expect(report.processed == [disable.id])
        #expect(fm.fileExists(atPath: plist.path))
    }

    // MARK: 4. Login items whose location does not resolve

    @Test func unresolvedLoginItemIsFoundByNameInApplications() throws {
        let apps = root.appendingPathComponent("Applications")
        let granola = apps.appendingPathComponent("Granola.app")
        try fm.createDirectory(at: granola, withIntermediateDirectories: true)
        let g = PerformanceModule.loginGroup([.init(name: "Granola", url: nil),
                                              .init(name: "Granola.app", url: root.appendingPathComponent("Old/Granola.app")),
                                              .init(name: "Mystère", url: nil)],
                                             appFolders: [apps, root.appendingPathComponent("Applications/Utilities")])
        let granolaRows = g.allItems.filter { $0.name.hasPrefix("Granola") }
        #expect(granolaRows.allSatisfy { $0.action == .custom(PerformanceModule.Key.disableLoginItem) && $0.url?.path == granola.path })
        #expect(!granolaRows.isEmpty)
        #expect(!g.allItems.contains { $0.detail?.contains("Introuvable") == true })

        let unknown = try #require(g.allItems.first { $0.name == "Mystère" })
        #expect(unknown.detail == "Emplacement non résolu")
        #expect(unknown.symbol != "exclamationmark.triangle")
        #expect(!unknown.autoSelect && g.defaultSelection.isEmpty)
    }

    // MARK: 11. "Réactiver" remembers hidden login items

    @Test func historyRemembersHiddenLoginItems() {
        let suite = "vc-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let h = MaintenanceHistory(suiteName: suite)
        h.setLoginItem("/Applications/Foo.app", disabled: true, hidden: true)
        h.setLoginItem("/Applications/Bar.app", disabled: true)
        #expect(h.hiddenLoginItems == ["/Applications/Foo.app"])
        h.setLoginItem("/Applications/Foo.app", disabled: false)
        #expect(h.hiddenLoginItems.isEmpty && h.disabledLoginItems == ["/Applications/Bar.app"])
    }

    // MARK: 5-6. Persistence heuristics

    @Test func onlyTemporaryAndSharedFoldersAreSuspicious() {
        let home = URL(fileURLWithPath: "/Users/x")
        for p in ["/tmp/a", "/private/tmp/a", "/private/var/tmp/a", "/Users/Shared/a"] {
            #expect(ProtectionModule.isSuspiciousLocation(URL(fileURLWithPath: p), home: home), "\(p)")
        }
        for p in ["/Users/x/.local/bin/a", "/Users/x/.nvm/versions/node/v20/bin/node", "/Users/x/.cargo/bin/a", "/Users/x/.bun/bin/bun"] {
            #expect(!ProtectionModule.isSuspiciousLocation(URL(fileURLWithPath: p), home: home), "\(p)")
            #expect(ProtectionModule.isHiddenHomeLocation(URL(fileURLWithPath: p), home: home), "\(p)")
        }
        #expect(!ProtectionModule.isHiddenHomeLocation(URL(fileURLWithPath: "/Users/x/Library/a"), home: home))
    }

    @Test func persistenceVerdicts() {
        func sig(_ s: SignatureInfo.Status) -> SignatureInfo { SignatureInfo(status: s, teamID: nil, isApple: false, isNotarized: false) }
        typealias V = (String, Bool)?
        func v(_ s: SignatureInfo.Status, suspicious: Bool = false, hidden: Bool = false, machO: Bool = false) -> V {
            ProtectionModule.persistenceVerdict(sig(s), suspicious: suspicious, hidden: hidden, machO: machO).map { ($0.reason, $0.auto) }
        }
        // Invalid: listed, ticked only in a suspicious location.
        #expect(v(.invalid)?.1 == false)
        #expect(v(.invalid, hidden: true)?.1 == false)
        #expect(v(.invalid, suspicious: true)?.1 == true)
        // Unsigned: ticked only in /tmp or /Users/Shared; a hidden home folder is "à vérifier".
        #expect(v(.unsigned, suspicious: true)?.1 == true)
        #expect(v(.unsigned, hidden: true)?.1 == false)
        #expect(v(.unsigned, hidden: true)?.0.contains("à vérifier") == true)
        #expect(v(.unsigned) == nil)
        #expect(v(.unsigned, machO: true)?.1 == false)
        // Valid, not notarized: never ticked.
        #expect(v(.valid, suspicious: true)?.1 == false)
        #expect(v(.valid, hidden: true)?.1 == false)
        #expect(v(.valid) == nil)
    }

    @Test func hiddenHomeAgentIsListedButNotTicked() throws {
        let home = root.appendingPathComponent("home")
        let tool = try write("#!/bin/sh\n", "home/.local/bin/tool")
        let plist = try writePlist(["Label": "dev.local.tool", "ProgramArguments": [tool.path]], "dev.local.tool.plist",
                                   in: home.appendingPathComponent("Library/LaunchAgents"))
        let li = try #require(ProtectionModule.launchItem(plist, system: false))
        var checked: [URL] = []
        let item = try #require(ProtectionModule().persistenceItem(li, context: ModuleContext(home: home), check: {
            checked.append($0); return SignatureInfo(status: .unsigned, teamID: nil, isApple: false, isNotarized: false)
        }))
        #expect(!item.autoSelect)
        #expect(item.detail?.contains("à vérifier") == true)
        #expect(checked == [tool])
    }

    @Test func systemPersistenceItemNeedsAdmin() throws {
        let exe = root.appendingPathComponent("bin/agent")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]).write(to: exe)
        let plist = try writePlist(["Label": "dev.sys.agent", "Program": exe.path], "dev.sys.agent.plist", in: root.appendingPathComponent("LaunchDaemons"))
        let li = try #require(ProtectionModule.launchItem(plist, system: true))
        let item = try #require(ProtectionModule().persistenceItem(li, context: ModuleContext(home: root.appendingPathComponent("home")), check: { _ in
            SignatureInfo(status: .unsigned, teamID: nil, isApple: false, isNotarized: false)
        }))
        #expect(item.action == .custom("quarantine-launch-system"))
        #expect(item.needsAdmin && !item.autoSelect)
    }

    @Test func nodeUnderNvmIsAnInterpreter() throws {
        let home = root.appendingPathComponent("home")
        let node = try write("bin", "home/.nvm/versions/node/v20.1.0/bin/node")
        let script = try write("console.log(1)", "home/dev/server.js")
        let plist = try writePlist(["Label": "dev.server", "ProgramArguments": [node.path, script.path]], "dev.server.plist",
                                   in: home.appendingPathComponent("Library/LaunchAgents"))
        #expect(ProtectionModule.isInterpreter(node.path))
        #expect(ProtectionModule.isInterpreter("/opt/homebrew/bin/deno"))
        #expect(!ProtectionModule.isInterpreter("/tmp/node"))
        #expect(ProtectionModule.launchItem(plist, system: false)?.target == script)
        // The interpreter itself never goes to the quarantine.
        let onlyNode = try writePlist(["Label": "dev.repl", "ProgramArguments": [node.path]], "dev.repl.plist",
                                      in: home.appendingPathComponent("Library/LaunchAgents"))
        #expect(ProtectionModule.quarantinableProgram(of: onlyNode, remover: SafeRemover(home: home.path)) == nil)
    }

    // MARK: 7-9. Privacy

    func db(_ url: URL, _ sql: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        #expect(sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK)
    }

    func allGroups(_ g: ResultGroup) -> [ResultGroup] { [g] + g.groups.flatMap(allGroups) }

    @Test func browserDataIsNeverBulkSelectedAndSaysWhatIsLost() throws {
        let home = root.appendingPathComponent("home")
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try db(chrome.appendingPathComponent("History"), "CREATE TABLE visits (id INTEGER); INSERT INTO visits VALUES (1);")
        try db(chrome.appendingPathComponent("Network/Cookies"), "CREATE TABLE cookies (host_key TEXT); INSERT INTO cookies VALUES ('x');")
        try db(chrome.appendingPathComponent("Login Data"), "CREATE TABLE logins (x TEXT); INSERT INTO logins VALUES ('x');")
        try Data("{}".utf8).write(to: chrome.appendingPathComponent("Preferences"))
        let safari = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library")
        try fm.createDirectory(at: safari.appendingPathComponent("Cookies"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: safari.appendingPathComponent("Cookies/Cookies.binarycookies"))
        try fm.createDirectory(at: safari.appendingPathComponent("WebKit/WebsiteData"), withIntermediateDirectories: true)

        let g = Browsers.scan(context: ModuleContext(home: home), running: [])
        #expect(allGroups(g).allSatisfy { !$0.bulkSelectable })
        #expect(g.bulkItems.isEmpty)
        let items = g.allItems
        let cookies = items.filter { $0.name.hasPrefix("Cookies") }
        #expect(cookies.count == 2)
        #expect(cookies.allSatisfy { $0.detail?.contains("Vous serez déconnecté des sites") == true && $0.isIrreversible })
        #expect(items.first { $0.name == "Données des sites" }?.detail?.contains("Vous serez déconnecté des sites") == true)
        let passwords = try #require(items.first { $0.name == "Mots de passe enregistrés" })
        #expect(passwords.detail?.contains("Irréversible") == true && passwords.isIrreversible)
        #expect(items.first { $0.name == "Historique" }?.isIrreversible == true)
    }

    @Test func otherPrivacyGroupsAreNotBulkSelectable() {
        let ctx = ModuleContext(home: root)
        let call = ResultItem(id: "privacy.tcc.Camera.us.zoom.xos", name: "Zoom", action: .command(executable: "/usr/bin/tccutil",
                                                                                                    arguments: ["reset", "Camera", "us.zoom.xos"], admin: false))
        let tcc = ResultGroup(id: "privacy.tcc", title: "", groups: [ResultGroup(id: "privacy.tcc.Camera", title: "Caméra", items: [call])])
        let cammic = Privacy.cameraMicrophone(tcc)
        // Same ids as the permissions rows: one tick, one reset.
        #expect(cammic.allItems.map(\.id) == [call.id])
        for g in [cammic, Privacy.permissions(context: ctx), Privacy.recentItems(context: ctx), WiFi.group([.init(ssid: "Café", open: true)])] {
            #expect(allGroups(g).allSatisfy { !$0.bulkSelectable }, "\(g.id)")
            #expect(g.bulkItems.isEmpty, "\(g.id)")
        }
    }

    @Test func tccPermissionsAreNeverBulkSelected() throws {
        let home = root.appendingPathComponent("home")
        try db(Privacy.tccDatabase(home: home), """
            CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER);
            INSERT INTO access VALUES ('kTCCServiceCamera', 'us.zoom.xos', 0, 2);
            """)
        let g = Privacy.permissions(context: ModuleContext(home: home), appName: { _ in nil })
        #expect(g.allItems.count == 1)
        #expect(allGroups(g).allSatisfy { !$0.bulkSelectable } && g.bulkItems.isEmpty)
        #expect(Privacy.cameraMicrophone(g).allItems.map(\.id) == g.allItems.map(\.id))
    }

    // MARK: 10. Restoring a user launch agent

    @Test func bootstrapOnlyForUserLaunchAgents() {
        let home = "/Users/x"
        #expect(Quarantine.bootstrapArguments("/Users/x/Library/LaunchAgents/a.plist", home: home, uid: 501)
                == ["bootstrap", "gui/501", "/Users/x/Library/LaunchAgents/a.plist"])
        #expect(Quarantine.bootstrapArguments("/Users/x/Library/LaunchAgents/sub/a.plist", home: home, uid: 501) == nil)
        #expect(Quarantine.bootstrapArguments("/Users/x/Downloads/a.plist", home: home, uid: 501) == nil)
        #expect(Quarantine.bootstrapArguments("/Users/x/Library/LaunchAgents/a.txt", home: home, uid: 501) == nil)
        #expect(Quarantine.bootstrapArguments("/Library/LaunchAgents/a.plist", home: home, uid: 501) == nil)
    }

    @Test func restoringAnAgentBringsBackItsProgramAndReloadsIt() throws {
        let home = root.appendingPathComponent("home")
        let q = Quarantine(root: root.appendingPathComponent("Q"))
        let plist = try writePlist(["Label": "dev.x", "Program": "/x"], "dev.x.plist", in: home.appendingPathComponent("Library/LaunchAgents"))
        let program = try write("#!/bin/sh\n", "home/.x/run")
        let e = try q.add(plist, reason: "test")
        try q.add(program, reason: "Programme lancé par dev.x", linkedTo: e.id)
        let unrelated = try write("x", "home/other.bin")
        try q.add(unrelated, reason: "autre")

        var calls: [[String]] = []
        try q.restore(e.id, remover: SafeRemover(home: home.path), launchctl: { calls.append($0) })
        #expect(fm.fileExists(atPath: plist.path) && fm.fileExists(atPath: program.path))
        #expect(!fm.fileExists(atPath: unrelated.path))
        #expect(q.list().count == 1)
        #expect(calls == [["bootstrap", "gui/\(getuid())", plist.path]])

        // A plain file restores without any launchctl call; a simulation does nothing.
        var none: [[String]] = []
        let id = try #require(q.list().first?.id)
        try q.restore(id, remover: SafeRemover(dryRun: true, home: home.path), launchctl: { none.append($0) })
        try q.restore(id, remover: SafeRemover(home: home.path), launchctl: { none.append($0) })
        #expect(none.isEmpty && fm.fileExists(atPath: unrelated.path))
    }
}
