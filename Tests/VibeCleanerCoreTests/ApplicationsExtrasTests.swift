import Foundation
import Testing
@testable import VibeCleanerCore

extension ApplicationsTests {
    // MARK: Mach-O

    static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func le(_ v: UInt32) -> [UInt8] { be(v).reversed() }
    static let universal = Data(be(0xCAFE_BABE) + be(2) + be(0x0100_0007) + be(3) + be(4096) + be(10) + be(12)
                                + be(0x0100_000C) + be(0) + be(8192) + be(10) + be(14))
    static let intel = Data(le(0xFEED_FACF) + le(0x0100_0007) + le(3))
    static let i386 = Data(le(0xFEED_FACE) + le(7) + le(3))

    @Test func machOHeaders() {
        #expect(MachO.archs(Self.universal) == [.x86_64, .arm64])
        #expect(MachO.archs(Self.intel) == [.x86_64])
        #expect(MachO.archs(Self.i386) == [.i386])
        #expect(MachO.archs(Data(Self.be(0xFEED_FACE) + Self.be(18))) == [.ppc])
        // A Java class file shares the fat magic.
        #expect(MachO.archs(Data(Self.be(0xCAFE_BABE) + Self.be(0x0000_0034))).isEmpty)
        #expect(MachO.archs(Data("#!/bin/sh\n".utf8)).isEmpty)
    }

    @Test func compatibilityRules() {
        func app(_ archs: Set<CPUArch>, min: String? = nil) -> InstalledApp {
            InstalledApp(url: appURL, bundleID: "com.foo.Bar", name: "Bar App", archs: archs, minimumSystemVersion: min)
        }
        let os = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
        #expect(AppCompatibility.issue(app([.i386]), appleSilicon: true, rosetta: true, os: os)?.contains("32 bits") == true)
        #expect(AppCompatibility.issue(app([.x86_64]), appleSilicon: true, rosetta: true, os: os)?.contains("Rosetta") == true)
        #expect(AppCompatibility.issue(app([.x86_64]), appleSilicon: true, rosetta: false, os: os)?.contains("pas installé") == true)
        #expect(AppCompatibility.issue(app([.x86_64]), appleSilicon: false, rosetta: false, os: os) == nil)
        #expect(AppCompatibility.issue(app([.arm64]), appleSilicon: false, rosetta: false, os: os) != nil)
        #expect(AppCompatibility.issue(app([.x86_64, .arm64]), appleSilicon: true, rosetta: true, os: os) == nil)
        #expect(AppCompatibility.issue(app([]), appleSilicon: true, rosetta: true, os: os) == nil)
        #expect(AppCompatibility.issue(app([.arm64], min: "28.0"), appleSilicon: true, rosetta: true, os: os)?.contains("28.0") == true)
        #expect(AppCompatibility.issue(app([.arm64], min: "27.0"), appleSilicon: true, rosetta: true, os: os) == nil)
    }

    func makeExecutable(_ app: URL, _ bytes: Data) throws {
        let exe = app.appendingPathComponent("Contents/MacOS/bin")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: exe)
    }

    // MARK: Scan categories

    @Test func scanFlagsIncompatibleSuspiciousAndOrigins() async throws {
        let old = root.appendingPathComponent("Applications/Vieux.app")
        try makeApp(old, id: "com.vieux.App", extra: ["CFBundleExecutable": "bin"])
        try makeExecutable(old, Self.i386)
        let intel = root.appendingPathComponent("Applications/Intel.app")
        try makeApp(intel, id: "com.adobe.Intel", extra: ["CFBundleExecutable": "bin"])
        try makeExecutable(intel, Self.intel)
        let modern = root.appendingPathComponent("Applications/Moderne.app")
        try makeApp(modern, id: "com.moderne.App-setapp", extra: ["CFBundleExecutable": "bin"])
        try makeExecutable(modern, Self.universal)

        let apps = module().installedApps(home: home)
        #expect(apps.first { $0.bundleID == "com.moderne.App-setapp" }?.archs == [.x86_64, .arm64])

        let groups = await module().scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }
        let incompatible = try #require(groups.first { $0.id == "applications.incompatible" })
        #expect(Set(incompatible.groups.map(\.title)) == ["Vieux", "Intel"])
        #expect(incompatible.groups.allSatisfy { $0.id.hasPrefix("incompatible:") && ApplicationsModule.isAppGroup($0.id) })
        // Fake bundles carry no code signature.
        let suspicious = try #require(groups.first { $0.id == "applications.suspicious" })
        #expect(suspicious.groups.count == 3)
        // Source and vendor are filters of "Toutes les applications", no longer cards of their own.
        #expect(!groups.contains { $0.id == "applications.vendors" || $0.id == "applications.stores" })
        let all = try #require(groups.first { $0.id == "applications.all" })
        // Never every app at once: no card, menu or Vibe Check box ticks a list of apps, only app by app.
        #expect(groups.filter { ApplicationsModule.uninstallGroupIDs.contains($0.id) }.allSatisfy { !$0.bulkSelectable && $0.bulkItems.isEmpty })
        #expect(!all.groups.isEmpty && all.groups.allSatisfy { !$0.tickItems.isEmpty })
        let card = ResultGroup(id: "applications", title: "", groups: groups)
        #expect(!card.bulkItems.contains { !$0.id.contains("|") && $0.id.hasSuffix(".app") })
        #expect(Set(all.groups.compactMap { $0.tags[ApplicationsModule.vendorTag] }) == ["Adobe", AppOrigin.otherVendor])
        #expect(Set(all.groups.compactMap { $0.tags[ApplicationsModule.sourceTag] }) == ["Setapp", "Internet et autres"])
        #expect(all.groups.allSatisfy { ApplicationsModule.appURL(groupID: $0.id)?.pathExtension == "app" })
        #expect(groups.allSatisfy { $0.defaultSelection.isEmpty || $0.id == "applications.leftovers" })
    }

    @Test func storesOfLaunchers() throws {
        let launcher = root.appendingPathComponent("Applications/Jeu.app")
        try touch("Contents/MacOS/run.sh", in: launcher)
        try Data("#!/bin/sh\nopen steam://run/570\n".utf8).write(to: launcher.appendingPathComponent("Contents/MacOS/run.sh"))
        func app(_ url: URL, _ id: String, source: InstalledApp.Source = .other) -> InstalledApp {
            InstalledApp(url: url, bundleID: id, name: url.deletingPathExtension().lastPathComponent, source: source)
        }
        #expect(AppOrigin.store(app(launcher, "com.valve.jeu"), home: home) == .steam)
        #expect(AppOrigin.store(app(appURL, "com.blizzard.worldofwarcraft"), home: home) == .battleNet)
        #expect(AppOrigin.store(app(appURL, "com.foo.Bar", source: .appStore), home: home) == .appStore)
        let ide = home.appendingPathComponent("Applications/IntelliJ IDEA.app")
        #expect(AppOrigin.store(app(ide, "com.jetbrains.intellij"), home: home) == .other)
        try touch("Application Support/JetBrains/Toolbox", dir: true)
        #expect(AppOrigin.store(app(ide, "com.jetbrains.intellij"), home: home) == .toolbox)
        #expect(AppOrigin.vendor(app(ide, "com.jetbrains.intellij")) == "JetBrains")
        #expect(AppOrigin.vendor(app(appURL, "com.Microsoft.Word")) == "Microsoft")
    }

    @Test func steamLibraries() async throws {
        let steam = lib.appendingPathComponent("Application Support/Steam/steamapps")
        let extra = root.appendingPathComponent("Disque/SteamLibrary")
        try touch("libraryfolders.vdf", in: steam)
        try Data("""
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"\(extra.path)"
        \t}
        }
        """.utf8).write(to: steam.appendingPathComponent("libraryfolders.vdf"))
        for (dir, id, name, folder) in [(steam, "570", "Dota 2", "dota 2 beta"), (extra.appendingPathComponent("steamapps"), "620", "Portal 2", "Portal 2"),
                                        (steam, "999", "Absent", "absent")] {
            try touch("appmanifest_\(id).acf", in: dir)
            try Data("\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"\(name)\"\n\t\"installdir\"\t\t\"\(folder)\"\n}\n".utf8)
                .write(to: dir.appendingPathComponent("appmanifest_\(id).acf"))
            if id != "999" { try touch("common/\(folder)/game.bin", in: dir) }
        }
        let games = SteamLibrary.games(home: home)
        #expect(Set(games.map(\.name)) == ["Dota 2", "Portal 2"])
        #expect(games.first { $0.id == "620" }?.folder.path == extra.appendingPathComponent("steamapps/common/Portal 2").path)

        let groups = await module().scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }
        let group = try #require(groups.first { $0.id == "applications.steam" })
        #expect(group.groups.map(\.title) == ["Dota 2", "Portal 2"])
        #expect(group.allItems.count == 4 && group.defaultSelection.isEmpty)
    }

    // MARK: Associated files

    @Test func footprintHasPluginsInstallersBinariesDockAndLoginItems() throws {
        try touch("Audio/Plug-Ins/Components/BarSynth.component/Contents/Info.plist", plist: ["CFBundleIdentifier": "com.foo.Bar.synth"])
        try touch("Audio/Plug-Ins/Components/Other.component/Contents/Info.plist", plist: ["CFBundleIdentifier": "com.other.synth"])
        try touch("QuickLook/Bar App Preview.qlgenerator", dir: true)
        for f in ["Bar App 2.1.dmg", "Install Bar App (arm64).pkg", "Bar App Pro.dmg", "Bar App.txt"] { try touch(f, in: home.appendingPathComponent("Downloads")) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("bar").path,
                                                   withDestinationPath: appURL.path + "/Contents/Resources/bar")
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("other").path, withDestinationPath: "/usr/bin/true")
        try touch("Preferences/com.apple.dock.plist", plist: ["persistent-apps": [
            ["tile-data": ["file-data": ["_CFURLString": appURL.absoluteString, "_CFURLStringType": 15]]],
        ]])
        let login = LoginItems.Entry(name: "Bar Helper", url: appURL.appendingPathComponent("Contents/Library/LoginItems/Helper.app"))
        let pro = InstalledApp(url: root.appendingPathComponent("Applications/Bar App Pro.app"), bundleID: "com.foo.pro", name: "Bar App Pro")
        let f = AppFootprint(home: home, localLibrary: root.appendingPathComponent("Library"), receiptsDir: root.appendingPathComponent("receipts"),
                             binDirs: [bin], loginItems: [login, LoginItems.Entry(name: "Autre", url: URL(fileURLWithPath: "/Applications/Autre.app"))],
                             installed: [app, pro], downloads: true)
        let found = Set(f.footprint(of: app).map { $0.path.replacingOccurrences(of: root.path + "/", with: "") })
        #expect(found == ["home/Library/Audio/Plug-Ins/Components/BarSynth.component", "home/Library/QuickLook/Bar App Preview.qlgenerator",
                          "home/Downloads/Bar App 2.1.dmg", "home/Downloads/Install Bar App (arm64).pkg", "bin/bar"])
        #expect(f.isInDock(app) && !f.isInDock(pro))
        #expect(f.loginItems(of: app) == [login])

        let items = module().extraItems(app, finder: f)
        #expect(items.map(\.id) == [appURL.path + "|login:" + login.url!.path, appURL.path + "|dock"])
        #expect(items.last?.action == ItemAction.none)
        let g = ResultGroup(id: "all:" + appURL.path, title: "Bar App", items: items + [ResultItem(id: appURL.path + "|/Library/Caches/x", name: "x", action: .none)])
        #expect(ApplicationsModule.resetSelection(g) == [appURL.path + "|/Library/Caches/x"])
    }

    @Test func pluginsAndSystemExtensions() async throws {
        try touch("Screen Savers/Flottant.saver/Contents/Info.plist", plist: ["CFBundleIdentifier": "net.flottant.saver"])
        try touch("Audio/Plug-Ins/VST3/Vendeur/Reverb.vst3", dir: true)
        try touch("PreferencePanes/Apple.prefPane/Contents/Info.plist", plist: ["CFBundleIdentifier": "com.apple.pane"])
        try touch("QuickLook/Local.qlgenerator", in: root.appendingPathComponent("Library"), dir: true)
        let found = Plugins.find(libraries: [lib, root.appendingPathComponent("Library")])
        #expect(Set(found.map { "\($0.kind):\($0.url.lastPathComponent)" }) == ["savers:Flottant.saver", "audio:Reverb.vst3", "quicklook:Local.qlgenerator"])

        let out = """
        2 extension(s)
        --- com.apple.system_extension.network_extension (Go to 'System Settings > General > Login Items & Extensions > Network Extensions' to modify these system extension(s))
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.90.9/101.90.9)\tTailscale Network Extension\t[activated enabled]
        \t*\tAPPLE00000\tcom.apple.thing (1.0)\tApple\t[activated enabled]
        """
        #expect(Plugins.parseSystemExtensions(out) == [Plugins.SystemExtension(
            teamID: "W5364U7YZB", bundleID: "io.tailscale.ipn.macsys.network-extension", version: "1.90.9/101.90.9",
            name: "Tailscale Network Extension", state: "activated enabled")])

        var m = module()
        m.listSystemExtensions = { out }
        let groups = await m.scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }
        let plugins = try #require(groups.first { $0.id == "applications.plugins" })
        #expect(Set(plugins.groups.map(\.id)) == ["plugins.audio", "plugins.quicklook", "plugins.savers", "plugins.sysext"])
        #expect(plugins.allItems.count == 4 && plugins.defaultSelection.isEmpty)
    }

    // MARK: Leftovers, trash, installers, updates

    @Test func leftoversCoverEveryLibraryFolder() throws {
        let old = Date().addingTimeInterval(-90 * 86_400)
        let local = root.appendingPathComponent("Library")
        let user = ["Group Containers/group.com.gone.App", "Group Containers/ABCDE12345.com.gone.App", "Group Containers/TEAM123456.com.gone.Shared",
                    "Saved Application State/com.gone.App.savedState", "HTTPStorages/com.gone.App", "WebKit/com.gone.App", "Logs/com.gone.App"]
        for p in user { try touch(p, dir: true) }
        try touch("Cookies/com.gone.App.binarycookies")
        try touch("LaunchAgents/com.gone.agent.plist", plist: ["Label": "a", "Program": "/nonexistent/agent"])
        try touch("LaunchAgents/com.gone.tool.plist", plist: ["Label": "b", "ProgramArguments": ["/bin/sh"]])
        try touch("Preferences/com.gone.App.plist", in: local)
        try touch("Application Support/com.apple.Thing", in: local, dir: true)
        for p in user + ["Cookies/com.gone.App.binarycookies", "LaunchAgents/com.gone.agent.plist"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lib.appendingPathComponent(p).path)
        }
        let installed = InstalledApp(url: appURL, bundleID: "com.foo.Bar", name: "Bar App", teamID: "TEAM123456")
        let hits = Leftovers.find(home: home, localLibrary: local, installed: [installed], executableDirs: [], isRegistered: { _ in false })
        let byPath = Dictionary(uniqueKeysWithValues: hits.map { ($0.url.path.replacingOccurrences(of: root.path + "/", with: ""), $0.clear) })
        #expect(byPath == [
            "home/Library/Group Containers/group.com.gone.App": false, "home/Library/Group Containers/ABCDE12345.com.gone.App": false,
            "home/Library/Saved Application State/com.gone.App.savedState": true, "home/Library/HTTPStorages/com.gone.App": true,
            "home/Library/WebKit/com.gone.App": true, "home/Library/Logs/com.gone.App": true,
            "home/Library/Cookies/com.gone.App.binarycookies": true, "home/Library/LaunchAgents/com.gone.agent.plist": false,
            "Library/Preferences/com.gone.App.plist": false,
        ])
        let groups = module().leftoverGroups(hits, context: ModuleContext(home: home))
        let agent = try #require(groups.flatMap(\.items).first { $0.url?.lastPathComponent == "com.gone.agent.plist" })
        #expect(agent.action == .custom(PerformanceModule.Key.removeUserAgent))
    }

    @Test func trashedAppsKeepTheirLeftovers() async throws {
        let trashed = home.appendingPathComponent(".Trash/Parti.app")
        try makeApp(trashed, id: "com.parti.App")
        try makeApp(home.appendingPathComponent(".Trash/Sans traces.app"), id: "com.clean.App")
        try makeApp(home.appendingPathComponent(".Trash/Copie.app"), id: "com.foo.Bar")
        try makeApp(appURL, id: "com.foo.Bar")
        try touch("Preferences/com.parti.App.plist")
        try touch("Caches/com.parti.App", dir: true)
        try touch("Preferences/com.foo.Bar.plist")

        let m = module()
        let apps = m.installedApps(home: home)
        let entries = TrashedApps.find(home: home, installed: apps, finder: m.footprintFinder(home: home, installed: apps))
        #expect(entries.map(\.app.name) == ["Parti"])
        #expect(Set(entries[0].leftovers.map(\.lastPathComponent)) == ["com.parti.App.plist", "com.parti.App"])

        let groups = await m.scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }
        let group = try #require(groups.first { $0.id == "applications.trashed" })
        #expect(group.allItems.count == 2 && group.defaultSelection.isEmpty)
        // The same files are not offered twice as leftovers.
        let left = groups.first { $0.id == "applications.leftovers" }?.allItems.compactMap(\.url) ?? []
        #expect(!left.contains { $0.lastPathComponent.contains("com.parti.App") })
    }

    @Test func installersAndSystemUpdates() async throws {
        try makeApp(appURL, id: "com.foo.Bar")
        let docs = home.appendingPathComponent("Documents")
        for f in ["Bar App 3.0.dmg", "Archive.pkg"] { try touch(f, in: docs) }
        try touch("Bar App.dmg", in: home.appendingPathComponent("Downloads"))
        try touch("Caches/x.dmg")
        let found = [docs.appendingPathComponent("Bar App 3.0.dmg"), docs.appendingPathComponent("Archive.pkg"),
                     home.appendingPathComponent("Downloads/Bar App.dmg"), lib.appendingPathComponent("Caches/x.dmg"),
                     docs.appendingPathComponent("absent.dmg")]
        #expect(InstallerSearch.filter(found, home: home, fullDiskAccess: true) == Array(found.prefix(2)))
        #expect(InstallerSearch.filter(found, home: home).isEmpty) // Documents is never read without Full Disk Access

        try touch("SoftwareUpdate.plist", in: root, plist: ["RecommendedUpdates": [
            ["Display Name": "macOS 27.0.1", "Identifier": "MSU_UPDATE_26A434_patch_27.0.1_minor"],
        ]])
        var m = module()
        m.findInstallers = { _ in found }
        m.fullDiskAccess = true
        let groups = await m.scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }
        let installers = try #require(groups.first { $0.id == "applications.installers" })
        #expect(installers.items.count == 2 && installers.defaultSelection.isEmpty)
        #expect(installers.items.first { $0.name == "Bar App 3.0.dmg" }?.detail?.contains("déjà installée") == true)
        let updates = try #require(groups.first { $0.id == "applications.macos" })
        #expect(updates.items.map(\.name) == ["macOS 27.0.1"] && updates.items[0].action == ItemAction.none)
    }

    // MARK: Execution

    @Test func executeRemovesBundlesLastAndFlushesPreferences() async throws {
        let prefs = lib.appendingPathComponent("Preferences/com.foo.Bar.plist")
        // A simulation reports only files that exist (SafeRemover dry-run): create them in the temporary home.
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: prefs)
        let bundle = ResultItem(id: appURL.path, name: "Bar App", url: appURL, action: .delete(appURL, mode: .trash, admin: false))
        let pref = ResultItem(id: appURL.path + "|" + prefs.path, name: "p", url: prefs, action: .delete(prefs, mode: .trash, admin: false))
        let samePref = ResultItem(id: prefs.path, name: "p", url: prefs, action: .delete(prefs, mode: .trash, admin: false))
        let r = await module().execute([bundle, pref, samePref], context: ModuleContext(dryRun: true, home: home))
        #expect(r.processed == [pref.id, bundle.id])
        #expect(ApplicationsModule.removesPreferences([pref], home: home))
        #expect(!ApplicationsModule.removesPreferences([bundle], home: home))
    }
}

@Suite struct AppUpdatesTests {
    @Test func versionsCompareNumerically() {
        #expect(AppUpdates.isNewer("1.10", than: "1.9"))
        #expect(!AppUpdates.isNewer("2.0", than: "2"))
        #expect(AppUpdates.isNewer("3.69.4", than: "3.69.3"))
        #expect(!AppUpdates.isNewer("1.2b1", than: "1.2b2"))
    }

    @Test func appcastPicksTheHighestStableReleaseForThisSystem() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>120</sparkle:version><sparkle:shortVersionString>1.2</sparkle:shortVersionString></item>
        <item><enclosure url="https://x/a.zip" sparkle:version="130" sparkle:shortVersionString="1.3"/></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure sparkle:version="140" sparkle:shortVersionString="1.4b"/></item>
        <item><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure sparkle:version="150"/></item>
        </channel></rss>
        """
        let last = AppUpdates.latest(appcast: Data(xml.utf8), os: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        #expect(last?.build == "130")
        #expect(last?.short == "1.3")
    }

    @Test func storeAnswerGivesTheVersion() {
        #expect(AppUpdates.storeVersion(Data(#"{"resultCount":1,"results":[{"version":"4.2.1"}]}"#.utf8)) == "4.2.1")
        #expect(AppUpdates.storeVersion(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
    }

    @Test func updatesAreFoundWithoutTheNetworkAndAreLinksNotChoices() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("updates-\(UUID().uuidString)/Foo.app")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try (["CFBundleVersion": "100"] as NSDictionary).write(to: dir.appendingPathComponent("Contents/Info.plist"))
        let sparkle = InstalledApp(url: dir, bundleID: "com.foo", name: "Foo", version: "1.0",
                                   sparkleFeedURL: URL(string: "https://foo.example/appcast.xml"))
        let store = InstalledApp(url: URL(fileURLWithPath: "/Applications/Bar.app"), bundleID: "com.bar", name: "Bar", version: "2.0", source: .appStore)
        let updates = await AppUpdates.find([sparkle, store]) { url in
            url.host == "itunes.apple.com" ? Data(#"{"results":[{"version":"2.1"}]}"#.utf8)
                : Data("<rss><channel><item><enclosure sparkle:version=\"101\" sparkle:shortVersionString=\"1.1\"/></item></channel></rss>".utf8)
        }
        #expect(updates.map(\.available) == ["2.1", "1.1"])
        let items = updates.map(AppUpdates.item)
        #expect(items.allSatisfy { !$0.isActionable && $0.openLink != nil })
        #expect(items[0].openLink?.scheme == "macappstore")
        #expect(items[1].openLink?.path == dir.path)
    }

    @Test func uninstallReviewSaysAppsAndTheirData() {
        let items = [ResultItem(id: "/Applications/A.app", name: "A", size: 10, action: .none),
                     ResultItem(id: "/Applications/A.app|/x/prefs.plist", name: "p", action: .none)]
        #expect(ResultQueries.reviewTitle(items, action: "Désinstaller").hasPrefix("Désinstaller 1 app,"))
        #expect(ResultQueries.reviewNote(items)?.hasPrefix("Avec 1 fichier associé") == true)
    }
}

@Suite struct AppDiscoveryTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")

    func make(_ path: String, plist: [String: Any] = ["CFBundleIdentifier": "com.x"]) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try (plist as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    @Test func appsOutsideTheApplicationsFoldersAreKeptButNotCopiesNorBuilds() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let tool = try make("tools/solver/Solver.app")
        let download = try make("Downloads/Postman.app")
        let urls = [tool, download, try make("tools/__MACOSX/solver/Solver.app"), try make("Library/Foo.app"),
                    try make("tools/.hidden/Bar.app"), try make("tools/Host.app/Contents/Helper.app"), try make("Applications/Mine.app")]
        #expect(AppInventory.filterSpotlightApps(urls, home: home, fullDiskAccess: false) == [tool])
        #expect(AppInventory.filterSpotlightApps(urls, home: home, fullDiskAccess: true) == [tool, download])
    }

    @Test func iPhoneAppsAreReadFromTheirWrappedBundle() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("PDF.app")
        let inner = app.appendingPathComponent("Wrapper/PDF.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.pdf", "CFBundleShortVersionString": "3.1"] as NSDictionary).write(to: inner.appendingPathComponent("Info.plist"))
        try Data().write(to: app.appendingPathComponent("Wrapper/iTunesMetadata.plist"))
        let loaded = try #require(AppInventory.load(app, isSystem: false))
        #expect(loaded.bundleID == "com.pdf" && loaded.version == "3.1" && loaded.source == .appStore)
    }
}
