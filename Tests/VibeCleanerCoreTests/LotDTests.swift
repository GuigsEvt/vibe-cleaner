import Foundation
import Testing
@testable import VibeCleanerCore

/// Lot D: attribution of files to apps, leftovers, reset, protection of Apple apps, Fouillis selection safety.
/// Everything happens in a temporary folder; no system command runs.
@Suite struct LotDTests {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var lib: URL { home.appendingPathComponent("Library") }
    var apps: URL { root.appendingPathComponent("Applications") }

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-lotd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
        for d in ["Documents", "Downloads", "Pictures", "Library"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func touch(_ rel: String, in base: URL? = nil, dir: Bool = false, plist: [String: Any]? = nil, data: Data? = nil) throws -> URL {
        let url = (base ?? lib).appendingPathComponent(rel)
        if dir { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try data ?? plist.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } ?? Data("x".utf8)
        try bytes.write(to: url)
        return url
    }

    func makeApp(_ url: URL, id: String) throws {
        try touch("Contents/Info.plist", in: url, plist: ["CFBundleIdentifier": id])
    }

    func finder(_ installed: [InstalledApp], loginItems: [LoginItems.Entry] = []) -> AppFootprint {
        AppFootprint(home: home, localLibrary: root.appendingPathComponent("Library"),
                     receiptsDir: root.appendingPathComponent("receipts"), loginItems: loginItems, installed: installed)
    }

    func module() -> ApplicationsModule {
        var m = ApplicationsModule()
        m.applicationDirs = [apps]
        m.systemApplicationDirs = []
        m.localLibrary = root.appendingPathComponent("Library")
        m.receiptsDir = root.appendingPathComponent("receipts")
        m.darwinDirs = []
        m.binDirs = []
        m.loginItems = []
        m.findInstallers = { _ in [] }
        m.listSystemExtensions = { "" }
        m.softwareUpdatePlist = root.appendingPathComponent("SoftwareUpdate.plist")
        return m
    }

    static func random(_ count: Int, seed: UInt64) -> Data {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        return Data((0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    // MARK: 1. Name matching between two apps with the same name

    @Test func sameNameAppsNeverClaimFilesByName() throws {
        let a = InstalledApp(url: apps.appendingPathComponent("CleanShot X.app"), bundleID: "pl.maketheweb.cleanshotx", name: "CleanShot X")
        let b = InstalledApp(url: apps.appendingPathComponent("Setapp/CleanShot X.app"), bundleID: "pl.maketheweb.cleanshotx-setapp", name: "CleanShot X")
        try touch("Application Support/CleanShot X", dir: true)
        try touch("Preferences/pl.maketheweb.cleanshotx.plist")
        let f = finder([a, b])
        #expect(f.footprint(of: a).map(\.lastPathComponent) == ["pl.maketheweb.cleanshotx.plist"])
        #expect(f.footprint(of: b).isEmpty)
        // Alone, the app still gets its folder named after it.
        #expect(finder([a]).footprint(of: a).map(\.lastPathComponent).contains("CleanShot X"))
    }

    // MARK: 2. Trashed apps

    @Test func trashedAppNeverTakesFilesOfAnInstalledNamesake() throws {
        let trashedURL = home.appendingPathComponent(".Trash/Foo Tool.app")
        try makeApp(trashedURL, id: "com.foo.old")
        let installed = InstalledApp(url: apps.appendingPathComponent("Foo Tool.app"), bundleID: "com.foo.new", name: "Foo Tool")
        try touch("Application Support/Foo Tool", dir: true)
        try touch("Preferences/com.foo.old.plist")
        let entries = TrashedApps.find(home: home, installed: [installed], finder: finder([installed]), locate: { _ in [] })
        #expect(entries.count == 1)
        #expect(entries.first?.leftovers.map(\.lastPathComponent) == ["com.foo.old.plist"])
    }

    @Test func trashedAppStillInstalledElsewhereIsIgnored() throws {
        try makeApp(home.appendingPathComponent(".Trash/Foo Tool.app"), id: "com.foo.old")
        try touch("Preferences/com.foo.old.plist")
        let elsewhere = TrashedApps.find(home: home, installed: [], finder: finder([]),
                                         locate: { _ in [URL(fileURLWithPath: "/Volumes/Disque/Applications/Foo Tool.app")] })
        #expect(elsewhere.isEmpty)
        let onlyTrash = TrashedApps.find(home: home, installed: [], finder: finder([]),
                                         locate: { _ in [URL(fileURLWithPath: "/Volumes/Disque/.Trashes/501/Foo Tool.app")] })
        #expect(onlyTrash.count == 1)
    }

    // MARK: 3. Embedded ids shared by several apps

    @Test func sharedEmbeddedIDsAreNotAttributed() throws {
        let a = InstalledApp(url: apps.appendingPathComponent("Alpha.app"), bundleID: "com.alpha.app", name: "Alpha",
                             embeddedBundleIDs: ["com.vendor.updater", "com.alpha.helper"])
        let b = InstalledApp(url: apps.appendingPathComponent("Bravo.app"), bundleID: "com.bravo.app", name: "Bravo",
                             embeddedBundleIDs: ["com.vendor.updater"])
        try touch("Preferences/com.vendor.updater.plist")
        try touch("Preferences/com.alpha.helper.plist")
        let f = finder([a, b])
        #expect(f.footprint(of: a).map(\.lastPathComponent) == ["com.alpha.helper.plist"])
        #expect(f.footprint(of: b).isEmpty)
    }

    // MARK: 4–6. Leftovers

    @Test func pluginsExtensionsAndReceiptsAreKnownIDs() throws {
        try touch("Audio/Plug-Ins/Components/Synth.component/Contents/Info.plist", plist: ["CFBundleIdentifier": "com.synthco.synth"])
        try touch("PreferencePanes/Panneau.prefPane/Contents/Info.plist", plist: ["CFBundleIdentifier": "net.panel.pane"])
        let receipts = root.appendingPathComponent("receipts")
        try touch("org.pkgvendor.tool.plist", in: receipts)
        try touch("org.pkgvendor.tool.bom", in: receipts)
        let sysext = Plugins.parseSystemExtensions("""
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        *\t*\tABCDE12345\tio.netguard.filter (1.0/1)\tNetGuard\t[activated enabled]
        """)
        let ids = Leftovers.componentIDs(libraries: [lib], systemExtensions: sysext, receiptsDir: receipts)
        #expect(Set(ids) == ["com.synthco.synth", "net.panel.pane", "io.netguard.filter", "org.pkgvendor.tool"])

        for p in ["com.synthco.synth.plist", "net.panel.pane.plist", "io.netguard.filter.plist", "org.pkgvendor.tool.plist",
                  "org.pkgvendor.other.plist", "com.gone.app.plist"] {
            try touch("Preferences/\(p)")
        }
        let hits = Leftovers.find(home: home, installed: [], executableDirs: [], isRegistered: { _ in false }, componentIDs: ids)
        #expect(hits.map(\.url.lastPathComponent) == ["com.gone.app.plist"])
    }

    @Test func containersAreNeverPreselected() throws {
        let old = Date().addingTimeInterval(-90 * 86_400)
        let container = try touch("Containers/com.gone.app", dir: true)
        let pref = try touch("Preferences/com.gone.app.plist")
        for u in [container, pref] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: u.path) }
        let hits = Leftovers.find(home: home, installed: [], executableDirs: [], isRegistered: { _ in false })
        let clear = Dictionary(uniqueKeysWithValues: hits.map { ($0.url.lastPathComponent, $0.clear) })
        #expect(clear == ["com.gone.app": false, "com.gone.app.plist": true])
    }

    @Test func appleAndShortcutsGroupsAreNeverLeftovers() throws {
        for g in ["243LU875E5.groups.com.apple.podcasts", "group.is.workflow.my.app", "ABCDE12345.com.apple.notes",
                  "groups.com.apple.foo", "group.com.apple.bar", "group.com.gone.app"] {
            try touch("Group Containers/\(g)", dir: true)
        }
        try touch("Preferences/is.workflow.my.app.plist")
        let hits = Leftovers.find(home: home, installed: [], executableDirs: [], isRegistered: { _ in false })
        #expect(hits.map(\.url.lastPathComponent) == ["group.com.gone.app"])
    }

    // MARK: 7. Reset

    @Test func resetKeepsOnlyDataFolders() {
        let a = "/Applications/A.app"
        let lib = "/Users/me/Library"
        let keep = ["\(lib)/Application Support/A", "\(lib)/Caches/com.a", "\(lib)/Preferences/com.a.plist",
                    "\(lib)/Preferences/ByHost/com.a.123.plist", "\(lib)/Containers/com.a", "\(lib)/Group Containers/TEAM.com.a",
                    "\(lib)/Saved Application State/com.a.savedState", "\(lib)/Cookies/com.a.binarycookies",
                    "\(lib)/HTTPStorages/com.a", "\(lib)/WebKit/com.a", "\(lib)/Logs/A", "/Library/Caches/com.a"]
        let drop = ["/Library/PrivilegedHelperTools/com.a.helper", "/Library/LaunchDaemons/com.a.plist", "\(lib)/LaunchAgents/com.a.plist",
                    "\(lib)/Audio/Plug-Ins/Components/A.component", "\(lib)/Application Support/Avid/Audio/Plug-Ins/A.aaxplugin",
                    "/usr/local/bin/a", "/Users/me/Downloads/A 1.0.dmg", "\(lib)/Logs/DiagnosticReports/A-2026-10-20-101112.ips",
                    "/Library/Logs/DiagnosticReports/A_2026-10-20-101112.crash"]
        let items = [ResultItem(id: a, name: "A", action: .none)]
            + (keep + drop).map { ResultItem(id: "\(a)|\($0)", name: "f", action: .none) }
            + ["|receipt:com.a.pkg", "|login:/x", "|dock"].map { ResultItem(id: a + $0, name: "x", action: .none) }
        let g = ResultGroup(id: "all:" + a, title: "A", items: items)
        #expect(ApplicationsModule.resetSelection(g) == Set(keep.map { "\(a)|\($0)" }))
    }

    // MARK: 8. Shortcuts uninstall plan

    @Test func uninstallPlanIncludesLoginItems() throws {
        let appURL = apps.appendingPathComponent("Bar App.app")
        try makeApp(appURL, id: "com.foo.Bar")
        let helper = appURL.appendingPathComponent("Contents/Library/LoginItems/Helper.app")
        try makeApp(helper, id: "com.foo.Bar.helper")
        let login = LoginItems.Entry(name: "Bar Helper", url: helper)
        var m = module()
        m.loginItems = [login]
        let plan = try #require(m.uninstallPlan(for: appURL, context: ModuleContext(dryRun: true, home: home)))
        #expect(plan.items.contains { $0.id == appURL.path + "|login:" + login.url!.path })
    }

    // MARK: 9. Apple apps outside /System

    @Test func downloadedAppleAppsAreRemovable() {
        let xcode = InstalledApp(url: URL(fileURLWithPath: "/Applications/Xcode.app"), bundleID: "com.apple.dt.Xcode", name: "Xcode")
        let safari = InstalledApp(url: URL(fileURLWithPath: "/Applications/Safari.app"), bundleID: "com.apple.Safari", name: "Safari")
        let restricted = InstalledApp(url: URL(fileURLWithPath: "/Applications/Outil Apple.app"), bundleID: "com.apple.outil",
                                      name: "Outil Apple", isRestricted: true)
        let underSystem = InstalledApp(url: URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications/Safari.app"),
                                       bundleID: "com.apple.Safari", name: "Safari")
        let thirdUnderSystem = InstalledApp(url: URL(fileURLWithPath: "/System/Library/CoreServices/Foo.app"), bundleID: "com.foo.x", name: "Foo")
        #expect(!xcode.isProtected)
        #expect(safari.isProtected && restricted.isProtected && underSystem.isProtected && thirdUnderSystem.isProtected)
    }

    @Test func restrictedFlagIsReadFromTheBundle() throws {
        let url = apps.appendingPathComponent("Libre.app")
        try makeApp(url, id: "com.apple.libre")
        let app = try #require(AppInventory.load(url, isSystem: false))
        #expect(!app.isRestricted && !app.isProtected)
    }

    // MARK: 10–13. Fouillis

    func clutterScan(_ m: ClutterModule) async -> [ResultGroup] {
        await m.scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }
    }

    func oldOptions() -> ClutterModule.Options {
        var o = ClutterModule.Options()
        o.now = Date().addingTimeInterval(60 * 86_400)
        return o
    }

    @Test func usedInstallerNeedsAnInstalledApp() async throws {
        let dl = home.appendingPathComponent("Downloads")
        let match = try touch("Outil 2.1.dmg", in: dl, data: Data(count: 1000)).resolvingSymlinksInPath()
        try touch("Setup.dmg", in: dl, data: Data(count: 1000))
        try touch("Outil.pkg", in: dl, data: Data(count: 1000))
        try touch("Outil.zip", in: dl, data: Data(".app/Contents/".utf8))
        try touch("Outil secret.dmg", in: dl, data: Data("encrcdsa".utf8) + Data(count: 1000))
        try touch("Outil ancien.dmg", in: dl, data: Data(count: 1000) + Data("cdsaencr".utf8))
        var m = ClutterModule(options: oldOptions())
        m.installedAppNames = { _ in ["Outil"] }
        let groups = await clutterScan(m)
        let downloads = try #require(groups.first { $0.id == "clutter.downloads" })
        let selected = Set(downloads.defaultSelection.map { URL(fileURLWithPath: $0).lastPathComponent })
        #expect(selected == [match.lastPathComponent, "Outil.pkg"])
        #expect(ClutterModule.isEncryptedDiskImage(dl.appendingPathComponent("Outil secret.dmg")))
        #expect(ClutterModule.isEncryptedDiskImage(dl.appendingPathComponent("Outil ancien.dmg")))
        #expect(!ClutterModule.isEncryptedDiskImage(dl.appendingPathComponent("Setup.dmg")))
    }

    @Test func keptCopyIsNeverPreselectedThroughDownloads() async throws {
        let content = Self.random(200 * 1024, seed: 71)
        try touch("Outil.dmg", in: home.appendingPathComponent("Downloads"), data: content)
        try touch("Outil copy.dmg", in: home.appendingPathComponent("Downloads"), data: content)
        var m = ClutterModule(options: oldOptions())
        m.installedAppNames = { _ in ["Outil"] }
        let groups = await clutterScan(m)
        let selection = groups.reduce(into: Set<String>()) { $0.formUnion($1.defaultSelection) }
        let set = try #require(groups.first { $0.id == "clutter.duplicates" }?.groups.first)
        #expect(set.items.count == 2)
        #expect(!selection.contains(set.items[0].id) && selection.contains(set.items[1].id))
        #expect(ResultQueries.fullySelectedCopySets(groups, selection: selection).isEmpty)
    }

    @Test func duplicateCopyIsKeptWhenNoOtherCopySurvives() async throws {
        let content = Self.random(200 * 1024, seed: 72)
        let kept = try touch("Documents/a.bin", in: home, data: content)
        try touch("Downloads/a.bin", in: home, data: content)
        let m = ClutterModule()
        let groups = await clutterScan(m)
        let set = try #require(groups.first { $0.id == "clutter.duplicates" }?.groups.first)
        let copy = set.items[1]
        let ctx = ModuleContext(dryRun: true, home: home)

        let ok = await m.execute([copy], context: ctx)
        #expect(ok.processed == [copy.id] && ok.failures.isEmpty)
        // Every copy selected: none is removed.
        let all = await m.execute(set.items, context: ctx)
        #expect(all.processed.isEmpty && all.failures.count == 2)
        // The kept copy changed size: the other one stays.
        try Data(count: 10).write(to: kept)
        let changed = await m.execute([copy], context: ctx)
        #expect(changed.processed.isEmpty && changed.failures.map(\.id) == [copy.id])
        try FileManager.default.removeItem(at: kept)
        let gone = await m.execute([copy], context: ctx)
        #expect(gone.processed.isEmpty && gone.failures.count == 1)
    }

    @Test func packagesCountAsOneLargeFile() async throws {
        try touch("Documents/Windows.pvm/disk.hdd", in: home, data: Self.random(150 * 1024, seed: 73))
        try touch("Documents/Windows.pvm/config.pvs", in: home, data: Self.random(150 * 1024, seed: 74))
        try touch("Documents/Disque.sparsebundle/bands/0", in: home, data: Self.random(200 * 1024, seed: 75))
        try touch("Documents/maquette.psd", in: home, data: Self.random(200 * 1024, seed: 76))
        try touch("Pictures/Photos.photoslibrary/originals/a.bin", in: home, data: Self.random(400 * 1024, seed: 77))
        var o = ClutterModule.Options()
        o.largeMinSize = 250 * 1024
        let groups = await clutterScan(ClutterModule(options: o))
        let large = try #require(groups.first { $0.id == "clutter.large" })
        let names = Set(large.allItems.compactMap(\.url?.lastPathComponent))
        #expect(names == ["Windows.pvm"])
        o.largeMinSize = 150 * 1024
        let smaller = try #require(await clutterScan(ClutterModule(options: o)).first { $0.id == "clutter.large" })
        #expect(Set(smaller.allItems.compactMap(\.url?.lastPathComponent)) == ["Windows.pvm", "Disque.sparsebundle", "maquette.psd"])
        let pvm = try #require(smaller.allItems.first { $0.url?.lastPathComponent == "Windows.pvm" })
        #expect(pvm.size >= 300 * 1024)
    }
}
