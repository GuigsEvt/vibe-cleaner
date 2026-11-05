import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct ApplicationsTests {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var lib: URL { home.appendingPathComponent("Library") }
    var appURL: URL { root.appendingPathComponent("Applications/Bar App.app") }

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Directory listings return /private/var/... paths: compare against the real path.
        root = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
    }

    func touch(_ rel: String, in base: URL? = nil, dir: Bool = false, plist: [String: Any]? = nil) throws {
        let url = (base ?? lib).appendingPathComponent(rel)
        if dir { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try plist.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } ?? Data("x".utf8)
        try data.write(to: url)
    }

    func makeApp(_ url: URL, id: String, extra: [String: Any] = [:]) throws {
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.2"]
        info.merge(extra) { $1 }
        try touch("Contents/Info.plist", in: url, plist: info)
    }

    var app: InstalledApp {
        InstalledApp(url: appURL, bundleID: "com.foo.Bar", name: "Bar App", teamID: "TEAM123",
                     appGroups: ["group.com.foo.shared"], privilegedExecutables: ["com.foo.Bar.helper"])
    }

    /// Every system source replaced by the temporary folder or an empty answer: no command runs, nothing real is read.
    func module() -> ApplicationsModule {
        var m = ApplicationsModule()
        m.applicationDirs = [root.appendingPathComponent("Applications")]
        m.systemApplicationDirs = []
        m.localLibrary = root.appendingPathComponent("Library")
        m.receiptsDir = root.appendingPathComponent("receipts")
        m.darwinDirs = []
        m.binDirs = []
        m.loginItems = []
        m.findInstallers = { _ in [] }
        m.listSystemExtensions = { "" }
        m.softwareUpdatePlist = root.appendingPathComponent("SoftwareUpdate.plist")
        m.appleSilicon = true
        m.rosetta = true
        return m
    }

    func finder(_ installed: [InstalledApp]) -> AppFootprint {
        AppFootprint(home: home, localLibrary: root.appendingPathComponent("Library"),
                     receiptsDir: root.appendingPathComponent("receipts"), installed: installed)
    }

    // MARK: Rules

    @Test func bundleIDRule() {
        #expect(AppMatch.matchesBundleID("com.foo.Bar", "com.foo.bar"))
        #expect(AppMatch.matchesBundleID("com.foo.Bar.plist", "com.foo.Bar"))
        #expect(AppMatch.matchesBundleID("com.foo.Bar.helper.savedState", "com.foo.Bar"))
        #expect(!AppMatch.matchesBundleID("com.foo.Barista.plist", "com.foo.Bar"))
        #expect(!AppMatch.matchesBundleID("com.foo", "com.foo.Bar"))
    }

    @Test func nameRuleNeedsEveryWord() {
        #expect(AppMatch.matchesAppName("Visual Studio Code", "Visual Studio Code"))
        #expect(AppMatch.matchesAppName("visual-studio-code_cache", "Visual Studio Code"))
        #expect(!AppMatch.matchesAppName("Code", "Visual Studio Code"))
        #expect(!AppMatch.matchesAppName("Code Cache", "Code"))
        #expect(!AppMatch.matchesAppName("Bar", "Bar"))
    }

    @Test func nameRuleRejectsVersionSuffix() {
        #expect(!AppMatch.matchesAppName("Photoshop 2024", "Photoshop"))
        #expect(!AppMatch.matchesAppName("Photoshop2024", "Photoshop"))
        #expect(AppMatch.matchesAppName("Photoshop Settings", "Photoshop"))
        #expect(AppMatch.matchesAppName("Adobe Photoshop 2024", "Adobe Photoshop 2024"))
    }

    @Test func reverseDNSExtraction() {
        #expect(AppMatch.reverseDNS("com.foo.Bar.plist", stripping: ["plist"]) == "com.foo.Bar")
        #expect(AppMatch.reverseDNS("com.foo.Bar") == "com.foo.Bar")
        #expect(AppMatch.reverseDNS("Google") == nil)
        #expect(AppMatch.reverseDNS("com.foo") == nil)
        #expect(AppMatch.reverseDNS("1.2.3") == nil)
        #expect(AppMatch.reverseDNS("Foo Bar.baz.qux") == nil)
    }

    // MARK: Footprint

    @Test func footprintOnFakeHome() throws {
        let matching = ["Application Support/com.foo.Bar", "Application Support/Bar App", "Caches/bar-app_cache",
                        "Caches/com.foo.Bar", "Containers/com.foo.Bar", "Containers/com.foo.Bar.ShareExtension",
                        "Group Containers/group.com.foo.shared", "Group Containers/TEAM123.com.foo.Bar",
                        "Saved Application State/com.foo.Bar.savedState", "HTTPStorages/com.foo.Bar", "WebKit/com.foo.Bar",
                        "Logs/Bar App"]
        let other = ["Application Support/Bar App 2", "Application Support/Bar", "Caches/com.foo.Barista",
                     "Containers/com.foo.Bar.pro", "Group Containers/OTHER99.com.foo.Bar", "Group Containers/TEAM123.com.foo.Other",
                     "Application Support/com.apple.Bar App"]
        for p in matching + other { try touch(p, dir: true) }
        let files = ["Preferences/com.foo.Bar.plist", "Preferences/ByHost/com.foo.Bar.0000-1111.plist", "Preferences/Bar App.plist",
                     "Cookies/com.foo.Bar.binarycookies"]
        for f in files { try touch(f) }
        try touch("Preferences/com.foo.Bar.pro.plist")
        try touch("LaunchAgents/com.vendor.updater.plist", plist: ["Label": "x", "AssociatedBundleIdentifiers": "com.foo.Bar"])
        try touch("LaunchAgents/net.agent.plist", plist: ["Label": "y", "ProgramArguments": [appURL.path + "/Contents/MacOS/agent"]])
        try touch("LaunchAgents/net.unrelated.plist", plist: ["Label": "z", "Program": "/usr/local/bin/other"])
        try touch("LaunchDaemons/com.foo.Bar.helper.plist", in: root.appendingPathComponent("Library"), plist: ["Label": "h"])
        try touch("PrivilegedHelperTools/com.foo.Bar.helper", in: root.appendingPathComponent("Library"))
        try touch("com.foo.Bar.pkg.plist", in: root.appendingPathComponent("receipts"))
        try touch("com.foo.Bar.pkg.bom", in: root.appendingPathComponent("receipts"))
        // A symlink into an unrelated folder must never be reported (or followed).
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("Caches/com.foo.Bar.link"),
                                                   withDestinationURL: root.appendingPathComponent("elsewhere"))

        let pro = InstalledApp(url: root.appendingPathComponent("Applications/Bar Pro.app"), bundleID: "com.foo.Bar.pro", name: "Bar Pro")
        let found = Set(finder([app, pro]).footprint(of: app).map { $0.path.replacingOccurrences(of: root.path + "/", with: "") })

        var expected = Set((matching + files).map { "home/Library/" + $0 })
        expected.formUnion(["home/Library/LaunchAgents/com.vendor.updater.plist", "home/Library/LaunchAgents/net.agent.plist",
                            "Library/LaunchDaemons/com.foo.Bar.helper.plist", "Library/PrivilegedHelperTools/com.foo.Bar.helper",
                            "receipts/com.foo.Bar.pkg.plist", "receipts/com.foo.Bar.pkg.bom"])
        #expect(found == expected)
    }

    @Test func sharedGroupContainersBelongToNoSingleApp() throws {
        try touch("Group Containers/TEAM123.Office", dir: true)
        try touch("Group Containers/group.com.foo.shared", dir: true)
        let word = InstalledApp(url: appURL, bundleID: "com.foo.Word", name: "Word", appGroups: ["TEAM123.Office", "group.com.foo.shared"])
        let excel = InstalledApp(url: appURL, bundleID: "com.foo.Excel", name: "Excel", appGroups: ["TEAM123.Office"])
        let found = finder([word, excel]).footprint(of: word).map(\.lastPathComponent)
        #expect(found == ["group.com.foo.shared"])
        // Name matching does not take files named after another installed app's id.
        try touch("Application Support/com.foo.excel.word", dir: true)
        try touch("Application Support/Word Data", dir: true)
        #expect(finder([word, excel]).footprint(of: word).map(\.lastPathComponent).contains("Word Data"))
        #expect(!finder([word, excel]).footprint(of: word).map(\.lastPathComponent).contains("com.foo.excel.word"))
    }

    // MARK: Inventory and scan

    @Test func inventoryReadsBundlesOneLevelDeep() throws {
        try makeApp(appURL, id: "com.foo.Bar", extra: ["SUFeedURL": "https://example.com/appcast.xml"])
        try makeApp(root.appendingPathComponent("Applications/Utilities/Tool.app"), id: "com.foo.Tool")
        try makeApp(root.appendingPathComponent("Applications/A/B/Deep.app"), id: "com.foo.Deep")
        try makeApp(root.appendingPathComponent("System/Safari.app"), id: "com.apple.Safari")
        try touch("Contents/_MASReceipt/receipt", in: appURL)
        try makeApp(appURL.appendingPathComponent("Contents/Library/LoginItems/Launcher.app"), id: "com.foo.launcher")

        var m = ApplicationsModule()
        m.applicationDirs = [root.appendingPathComponent("Applications")]
        m.systemApplicationDirs = [root.appendingPathComponent("System")]
        let apps = m.installedApps(home: home)
        #expect(Set(apps.compactMap(\.bundleID)) == ["com.foo.Bar", "com.foo.Tool", "com.apple.Safari"])
        let bar = try #require(apps.first { $0.bundleID == "com.foo.Bar" })
        #expect(bar.name == "Bar App" && bar.version == "1.2" && bar.source == .appStore)
        #expect(bar.sparkleFeedURL?.absoluteString == "https://example.com/appcast.xml")
        #expect(bar.embeddedBundleIDs == ["com.foo.launcher"])
        #expect(apps.first { $0.bundleID == "com.apple.Safari" }?.isProtected == true)
        #expect(!bar.isProtected)
    }

    @Test func unusedThreshold() {
        let old = InstalledApp(url: appURL, bundleID: "com.foo.Bar", name: "Bar App", lastUsed: Date().addingTimeInterval(-200 * 86_400))
        let recent = InstalledApp(url: appURL, bundleID: "com.foo.Bar", name: "Bar App", lastUsed: Date())
        let never = InstalledApp(url: appURL, bundleID: "com.foo.Bar", name: "Bar App")
        #expect(old.isUnused() && !recent.isUnused() && !never.isUnused())
    }

    @Test func scanBuildsGroups() async throws {
        try makeApp(appURL, id: "com.foo.Bar")
        try touch("Preferences/com.foo.Bar.plist")
        try touch("Preferences/com.gone.Thing.plist")
        let m = module()
        let groups = await m.scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }

        let all = try #require(groups.first { $0.id == "applications.all" })
        let bar = try #require(all.groups.first)
        #expect(bar.items.map(\.id) == [appURL.path, appURL.path + "|" + lib.appendingPathComponent("Preferences/com.foo.Bar.plist").path])
        #expect(all.defaultSelection.isEmpty)
        let left = try #require(groups.first { $0.id == "applications.leftovers" })
        #expect(left.allItems.map(\.url) == [lib.appendingPathComponent("Preferences/com.gone.Thing.plist")])

        let report = await m.execute(bar.items + bar.items, context: ModuleContext(dryRun: true, home: home))
        #expect(report.processed.count == 2)
        #expect(FileManager.default.fileExists(atPath: appURL.path))
    }

    @Test func footprintHasCrashReportsAndDarwinFolders() throws {
        let darwin = root.appendingPathComponent("var/folders/C")
        try touch("com.foo.Bar", in: darwin, dir: true)
        try touch("com.other.App", in: darwin, dir: true)
        try touch("Logs/DiagnosticReports/Bar App-2026-10-20-101112.ips")
        try touch("Logs/DiagnosticReports/Bar App Pro-2026-10-20-101112.ips")
        try touch("Logs/DiagnosticReports/Bar App.txt")
        let f = AppFootprint(home: home, localLibrary: root.appendingPathComponent("Library"),
                             receiptsDir: root.appendingPathComponent("receipts"), darwinDirs: [darwin], installed: [app])
        let paths = Set(f.footprint(of: app).map(\.path))
        #expect(paths.contains(darwin.appendingPathComponent("com.foo.Bar").path))
        #expect(!paths.contains(darwin.appendingPathComponent("com.other.App").path))
        #expect(paths.contains(lib.appendingPathComponent("Logs/DiagnosticReports/Bar App-2026-10-20-101112.ips").path))
        #expect(!paths.contains { $0.contains("Bar App Pro") || $0.hasSuffix(".txt") })
    }

    @Test func launchdJobsAreStoppedBeforeRemoval() {
        var m = ApplicationsModule()
        m.localLibrary = root.appendingPathComponent("Library")
        let user = lib.appendingPathComponent("LaunchAgents/com.foo.Bar.agent.plist")
        let daemon = m.localLibrary.appendingPathComponent("LaunchDaemons/com.foo.Bar.helper.plist")
        #expect(m.launchdAction(user, home: home) == .custom(PerformanceModule.Key.removeUserAgent))
        #expect(m.launchdAction(daemon, home: home, uid: 501) == PerformanceModule.removeCommand(plist: daemon, domain: "system"))
        #expect(m.launchdAction(lib.appendingPathComponent("Preferences/com.foo.Bar.plist"), home: home) == nil)
    }

    @Test func resetKeepsBundleAndReceipts() {
        let g = ResultGroup(id: "all:/A.app", title: "A", items: [
            ResultItem(id: "/A.app", name: "A", action: .none),
            ResultItem(id: "/A.app|/Users/me/Library/Preferences/prefs.plist", name: "p", action: .none),
            ResultItem(id: "/A.app|receipt:com.a.pkg", name: "r", action: .none),
        ])
        #expect(ApplicationsModule.resetSelection(g) == ["/A.app|/Users/me/Library/Preferences/prefs.plist"])
    }

    @Test func bundlePathOfItems() {
        let bundle = ResultItem(id: appURL.path, name: "Bar App", url: appURL, action: .delete(appURL, mode: .trash, admin: false))
        let file = ResultItem(id: appURL.path + "|/x/y", name: "y", action: .delete(URL(fileURLWithPath: "/x/y"), mode: .trash, admin: false))
        #expect(ApplicationsModule.bundlePath(of: bundle) == appURL.path)
        #expect(ApplicationsModule.bundlePath(of: file) == appURL.path)
        #expect(ApplicationsModule.bundlePath(of: .file(URL(fileURLWithPath: "/x/z"))) == nil)
    }

    // MARK: Leftovers

    @Test func orphansAreDetectedConservatively() throws {
        let old = Date().addingTimeInterval(-90 * 86_400)
        for p in ["Preferences/com.gone.App.plist", "Preferences/com.apple.finder.plist", "Preferences/com.foo.Bar.plist",
                  "Preferences/com.foo.Bar.helper.plist", "Preferences/org.tool.mytool.plist", "Preferences/com.foo.launcher.plist",
                  "Preferences/loginwindow.plist", "Preferences/com.registered.App.plist", "Preferences/com.fresh.App.plist", "Preferences/com.foo.office.plist"] {
            try touch(p)
        }
        for p in ["Containers/com.gone.App", "Application Support/com.gone.App", "Application Support/Gone App",
                  "Caches/com.foo"] {
            try touch(p, dir: true)
        }
        for p in ["Preferences/com.gone.App.plist", "Containers/com.gone.App", "Application Support/com.gone.App",
                  "Preferences/org.tool.mytool.plist"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lib.appendingPathComponent(p).path)
        }
        let bin = root.appendingPathComponent("bin")
        try touch("mytool", in: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("mytool").path)

        let installed = InstalledApp(url: appURL, bundleID: "com.foo.Bar", name: "Bar App", embeddedBundleIDs: ["com.foo.launcher"])
        let hits = Leftovers.find(home: home, installed: [installed], executableDirs: [bin],
                                  isRegistered: { $0.hasPrefix("com.registered") })
        let byPath = Dictionary(uniqueKeysWithValues: hits.map { ($0.url.path.replacingOccurrences(of: lib.path + "/", with: ""), $0.clear) })
        #expect(byPath == ["Preferences/com.gone.App.plist": true, "Containers/com.gone.App": false,
                           "Application Support/com.gone.App": false, "Preferences/com.fresh.App.plist": false])
        #expect(Set(hits.map(\.ownerID)) == ["com.gone.App", "com.fresh.App"])
    }
}
