import Foundation
import Testing
@testable import VibeCleanerCore

/// The Shortcuts uninstall action builds its list from these; nothing here executes.
@Suite struct UninstallPlanTests {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var apps: URL { root.appendingPathComponent("Applications") }

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
    }

    func write(_ url: URL, plist: [String: Any]? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try plist.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } ?? Data("x".utf8)
        try data.write(to: url)
    }

    func app(_ name: String, id: String) throws -> URL {
        let url = apps.appendingPathComponent("\(name).app")
        try write(url.appendingPathComponent("Contents/Info.plist"), plist: ["CFBundleIdentifier": id])
        return url
    }

    var module: ApplicationsModule {
        var m = ApplicationsModule()
        m.applicationDirs = [apps]
        m.systemApplicationDirs = []
        m.localLibrary = root.appendingPathComponent("Library")
        m.receiptsDir = root.appendingPathComponent("receipts")
        m.darwinDirs = []
        return m
    }

    @Test func planListsBundleThenFiles() throws {
        let bar = try app("Bar", id: "com.foo.Bar")
        let prefs = home.appendingPathComponent("Library/Preferences/com.foo.Bar.plist")
        try write(prefs)
        try write(home.appendingPathComponent("Library/Preferences/com.other.Thing.plist"))
        let plan = try #require(module.uninstallPlan(for: bar, context: ModuleContext(dryRun: true, home: home)))
        #expect(plan.items.map(\.id) == [bar.path, bar.path + "|" + prefs.path])
        #expect(plan.totalSize > 0 && !plan.needsAdmin)
        let text = plan.summary()
        #expect(text.contains("« Bar » et 1 fichier(s)") && text.contains(prefs.path) && !text.contains("com.other.Thing"))
        #expect(!text.contains("quittée") && plan.summary(running: true).contains("« Bar » est ouverte : elle sera d'abord quittée"))
        #expect(FileManager.default.fileExists(atPath: bar.path) && FileManager.default.fileExists(atPath: prefs.path))
    }

    @Test func protectedExcludedOrUnknownHaveNoPlan() throws {
        let apple = try app("Safari", id: "com.apple.Safari")
        let mine = try app("Vibe Cleaner", id: "ai.flowpace.vibecleaner")
        let bar = try app("Bar", id: "com.foo.Bar")
        let ctx = ModuleContext(dryRun: true, home: home)
        #expect(module.uninstallPlan(for: apple, context: ctx) == nil)
        #expect(module.uninstallPlan(for: mine, context: ctx) == nil)
        #expect(module.uninstallPlan(for: apps.appendingPathComponent("Gone.app"), context: ctx) == nil)
        #expect(module.uninstallPlan(for: bar, context: ModuleContext(dryRun: true, exclusions: [bar.path], home: home)) == nil)
        #expect(module.removableApps(home: home).map(\.name) == ["Bar"])
    }

    @Test func summaryIsCappedAndFlagsAdmin() {
        let a = InstalledApp(url: URL(fileURLWithPath: "/A/Foo.app"), bundleID: "com.foo", name: "Foo")
        let files = (0..<5).map { ResultItem.file(URL(fileURLWithPath: "/A/f\($0)"), size: 1) }
        let receipt = ResultItem(id: "/A/Foo.app|receipt:com.foo.pkg", name: "com.foo.pkg", detail: "Reçu",
                                 action: .command(executable: "/usr/sbin/pkgutil", arguments: ["--forget", "com.foo.pkg"], admin: true))
        let plan = UninstallPlan(app: a, items: files + [receipt])
        #expect(plan.needsAdmin)
        let lines = plan.summary(limit: 3).components(separatedBy: "\n")
        #expect(lines.count == 1 + 3 + 1 + 1)
        #expect(lines[4] == "• … et 3 autre(s)" && lines[5].contains("mot de passe administrateur"))
        #expect(plan.summary().contains("• com.foo.pkg — Reçu"))
    }
}
