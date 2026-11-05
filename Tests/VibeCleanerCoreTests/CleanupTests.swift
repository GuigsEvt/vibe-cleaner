import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct CleanupTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        // Resolved, as directory listings return /private/var rather than /var.
        let dir = fm.temporaryDirectory.appendingPathComponent("vc-cleanup-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: Junk.realPath(dir.path))
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 5000, data: Data? = nil) throws -> URL {
        let url = home.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? Data(repeating: 0x41, count: bytes)).write(to: url)
        return url
    }

    /// Caches written in the last 10 minutes are treated as in use (lot B): backdates an item and its direct children.
    func age(_ path: String, by seconds: TimeInterval = 86_400) throws {
        let url = home.appendingPathComponent(path), old = Date(timeIntervalSinceNow: -seconds)
        for u in [url] + ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []) {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path)
        }
    }

    func plist(_ path: String, _ dict: [String: Any]) throws {
        try file(path, data: try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0))
    }

    func scan(_ exclusions: [String] = []) async -> [ResultGroup] {
        await CleanupModule(scansSystemLocations: false)
            .scan(context: ModuleContext(exclusions: exclusions, home: home)) { _, _ in }
            .map { $0.pruned() }
    }

    func group(_ groups: [ResultGroup], _ id: String) -> ResultGroup? { groups.first { $0.id == id } }
    func paths(_ g: ResultGroup?) -> Set<String> { Set(g?.allItems.compactMap { $0.url?.lastPathComponent } ?? []) }

    @Test func findsCachesAndSkipsProtectedOnes() async throws {
        try file("Library/Caches/com.example.app/data.bin")
        try file("Library/Caches/CloudKit/db")
        try file("Library/Caches/com.apple.bird/db")
        try file("Library/Caches/GeoServices/tiles")
        try file("Library/Caches/ai.flowpace.vibecleaner/own")
        try file("Library/Caches/Homebrew/pkg.tar.gz")
        try file("Library/Caches/com.example.empty/.keep", bytes: 0)
        try file("Library/Containers/com.example.sb/Data/Library/Caches/WebKit/blob")
        try file(".npm/_cacache/index")
        try age("Library/Caches/com.example.app")
        try age("Library/Containers/com.example.sb/Data/Library/Caches/WebKit")

        let groups = await scan()
        let caches = try #require(group(groups, "cleanup.system.userCaches"))
        #expect(paths(caches) == ["com.example.app", "WebKit"])
        #expect(caches.defaultSelection.count == 2)
        #expect(caches.allItems.allSatisfy { if case .delete(_, .permanent, false) = $0.action { true } else { false } })

        let all = groups.flatMap(\.allItems).compactMap { $0.url?.path }
        for protected in ["CloudKit", "com.apple.bird", "GeoServices", "vibecleaner"] {
            #expect(!all.contains { $0.contains(protected) })
        }
        let dev = try #require(group(groups, "cleanup.system.devCaches"))
        #expect(Set(dev.allItems.map(\.name)) == ["npm", "Homebrew"])
    }

    @Test func skipsDisabledCategories() async throws {
        try file("Library/Caches/com.example.app/data.bin")
        try file("Library/Logs/com.example.app/a.log")
        #expect(CleanupModule.categories.contains("Caches utilisateur"))
        let groups = await CleanupModule(scansSystemLocations: false, disabledCategories: ["Caches utilisateur"])
            .scan(context: ModuleContext(home: home)) { _, _ in }
        #expect(group(groups, "cleanup.system.userCaches") == nil)
        #expect(!groups.isEmpty)
    }

    @Test func honoursUserExclusions() async throws {
        try file("Library/Caches/com.example.keep/a")
        try file("Library/Caches/com.example.drop/a")
        // Both spellings: SafeRemover compares the symlink-resolved path (/var/…), isExcluded the listed one (/private/var/…).
        let keep = home.appendingPathComponent("Library/Caches/com.example.keep").path
        let groups = await scan([keep, keep.replacingOccurrences(of: "/private/var/", with: "/var/")])
        #expect(paths(group(groups, "cleanup.system.userCaches")) == ["com.example.drop"])
    }

    @Test func findsElectronCaches() async throws {
        try file("Applications/Foo.app/Contents/Frameworks/Electron Framework.framework/Electron")
        try plist("Applications/Foo.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example.foo", "CFBundleName": "Foo"])
        try file("Library/Application Support/Foo/Cache/data_0")
        try file("Library/Application Support/Foo/Code Cache/js")
        let caches = try #require(group(await scan(), "cleanup.system.userCaches"))
        let foo = try #require(caches.groups.first { $0.title == "com.example.foo" })
        #expect(foo.items.count == 2)
    }

    @Test func findsLogsAndTrash() async throws {
        try file("Library/Logs/App/run.log")
        try file("Library/Logs/single.log")
        try file("Library/Containers/com.example.sb/Data/Library/Logs/sb.log")
        try file(".Trash/old.txt")
        try file(".Trash/.hidden-trashed", bytes: 0)

        let groups = await scan()
        let logs = try #require(group(groups, "cleanup.system.userLogs"))
        #expect(paths(logs) == ["run.log", "single.log", "sb.log"])
        #expect(logs.defaultSelection.count == 3)
        #expect(logs.allItems.allSatisfy { if case .delete(_, .trash, _) = $0.action { true } else { false } })

        let trash = try #require(group(groups, "cleanup.trash"))
        #expect(paths(trash) == ["old.txt", ".hidden-trashed"])
        #expect(trash.defaultSelection.count == 2)
        #expect(trash.allItems.allSatisfy { if case .delete(_, .permanent, _) = $0.action { true } else { false } })
    }

    @Test func findsBrokenPreferencesAndAgents() async throws {
        try file("Library/Preferences/com.example.bad.plist", data: Data("not a plist".utf8))
        try plist("Library/Preferences/com.example.good.plist", ["a": 1])
        try file("Library/Preferences/com.example.empty.plist", bytes: 0)
        try file("Library/Preferences/com.example.lockfile.plist.lockfile", data: Data("x".utf8))
        try plist("Library/LaunchAgents/com.example.broken.plist", ["Label": "com.example.broken", "Program": "/nonexistent/vc-agent"])
        try plist("Library/LaunchAgents/com.example.ok.plist", ["Label": "com.example.ok", "ProgramArguments": ["/bin/ls", "-l"]])
        try plist("Library/LaunchAgents/com.example.path.plist", ["Label": "com.example.path", "ProgramArguments": ["node", "x.js"]])

        let groups = await scan()
        #expect(paths(group(groups, "cleanup.system.brokenPrefs")) == ["com.example.bad.plist"])
        let agents = try #require(group(groups, "cleanup.system.brokenLaunchAgents"))
        #expect(agents.allItems.map(\.name) == ["com.example.broken"])
        #expect(agents.defaultSelection.count == 1)
    }

    @Test func keepsLatestIOSBackupPerDevice() async throws {
        let base = "Library/Application Support/MobileSync/Backup"
        let old = Date(timeIntervalSinceNow: -90 * 86_400), recent = Date(timeIntervalSinceNow: -86_400)
        try plist("\(base)/A/Info.plist", ["Device Name": "iPhone", "Target Identifier": "T1", "Last Backup Date": old])
        try file("\(base)/A/data")
        try plist("\(base)/B/Info.plist", ["Device Name": "iPhone", "Target Identifier": "T1"])
        try plist("\(base)/B/Status.plist", ["Date": recent])
        try file("\(base)/B/data")
        try plist("\(base)/C/Info.plist", ["Product Type": "iPad8,1"])
        try file("\(base)/C/data")
        try age("\(base)/C")

        let g = try #require(group(await scan(), "cleanup.system.iosBackups"))
        let selected = g.defaultSelection
        let path = { (n: String) in self.home.appendingPathComponent("\(base)/\(n)").path }
        #expect(selected.contains(path("A")))
        #expect(!selected.contains(path("B")))
        #expect(selected.contains(path("C")))
        #expect(g.groups.contains { $0.title == "Sauvegardes cassées" })
    }

    @Test func documentVersionSelectionRule() {
        let now = Date()
        let h: (Double) -> Date = { now.addingTimeInterval(-$0 * 3600) }
        // newest, +1 h (close → selected), +10 h (far → kept), +11 h (close → selected), oldest (kept).
        #expect(SystemJunkScanner.versionSelection([h(0), h(1), h(11), h(12), h(13)]) == [false, true, false, true, false])
        #expect(SystemJunkScanner.versionSelection([h(0), h(0.5)]) == [false, false])
        #expect(SystemJunkScanner.versionSelection([]) == [])
    }

    @Test func xcodeDerivedDataAndArchives() async throws {
        try file("Library/Developer/Xcode/DerivedData/MyApp-abcdefgh/Build/x")
        try file("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/m")
        try plist("Library/Developer/Xcode/Archives/2026-01-01/MyApp.xcarchive/Info.plist", ["Name": "MyApp"])
        try file("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A1)/Symbols/x")

        let g = try #require(group(await scan(), "cleanup.system.xcode"))
        let derived = try #require(g.groups.first { $0.title == "DerivedData" })
        #expect(Set(derived.items.map(\.name)) == ["MyApp", "ModuleCache.noindex"])
        #expect(derived.defaultSelection == [home.appendingPathComponent("Library/Developer/Xcode/DerivedData/MyApp-abcdefgh").path])
        #expect(g.defaultSelection.count == 1)
        #expect(g.allItems.count == 4)
        #expect(XcodeScanner.derivedDataName("Vibe-Cleaner-xyz") == "Vibe-Cleaner")
    }

    @Test func detectsSimulatorsWithMissingRuntime() throws {
        let devices = home.appendingPathComponent("Devices")
        for (udid, runtime) in [("U1", "com.apple.CoreSimulator.SimRuntime.iOS-17-0"), ("U2", "com.apple.CoreSimulator.SimRuntime.iOS-26-5")] {
            let d = devices.appendingPathComponent(udid)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            NSDictionary(dictionary: ["runtime": runtime, "name": "iPhone \(udid)"]).write(to: d.appendingPathComponent("device.plist"), atomically: true)
        }
        let found = XcodeScanner.unavailableDevices(in: devices, runtimes: ["com.apple.CoreSimulator.SimRuntime.iOS-26-5"])
        #expect(found.map(\.udid) == ["U1"])
        #expect(XcodeScanner.unavailableDevices(in: devices, runtimes: []).isEmpty)
    }

    @Test func mailDownloadsSelectOnlyUntouchedFiles() async throws {
        let untouched = try file("Library/Mail Downloads/\(UUID().uuidString)/invoice.pdf")
        let edited = try file("Library/Mail Downloads/edited.pdf")
        try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -86_400), .modificationDate: Date()], ofItemAtPath: edited.path)
        try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000), .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                             ofItemAtPath: untouched.path)
        try file("Library/Mail/V10/ACCOUNT-UUID/INBOX.mbox/X/Data/Attachments/42/2/photo.jpg")

        let g = try #require(group(await scan(), "cleanup.mail"))
        #expect(g.allItems.count == 3)
        let sel = g.defaultSelection
        #expect(!sel.contains(edited.path))
        if !NSWorkspaceRunning.mail {
            #expect(sel.contains(untouched.path))
            #expect(sel.count == 2)
        }
    }

    @Test func languagesOnlyFromUnsealedApps() async throws {
        try file("Applications/Unsigned.app/Contents/Resources/xh.lproj/Localizable.strings")
        try file("Applications/Unsigned.app/Contents/Resources/en.lproj/Localizable.strings")
        try file("Applications/Unsigned.app/Contents/Resources/zu.lproj/Main.nib")
        try file("Applications/Signed.app/Contents/Resources/xh.lproj/Localizable.strings")
        try plist("Applications/Signed.app/Contents/_CodeSignature/CodeResources",
                  ["files2": ["Resources/xh.lproj/Localizable.strings": ["hash2": Data()]]])

        let g = try #require(group(await scan(), "cleanup.system.languages"))
        #expect(g.allItems.map(\.name) == ["Unsigned — xh.lproj"])
        #expect(g.defaultSelection.isEmpty)
        #expect(AppBundleScanner.languageCode("French") == "fr")
        #expect(AppBundleScanner.languageCode("pt_BR") == "pt")
        #expect(AppBundleScanner.languageCode("jp") == "ja")
    }

    @Test func dryRunExecuteKeepsFiles() async throws {
        let cache = try file("Library/Caches/com.example.app/data.bin")
        try file(".Trash/old.txt")
        let groups = await scan()
        let sel = groups.reduce(into: Set<String>()) { $0.formUnion($1.defaultSelection) }
        let items = groups.flatMap(\.allItems).filter { sel.contains($0.id) }
        let report = await CleanupModule(scansSystemLocations: false).execute(items, context: ModuleContext(dryRun: true, home: home))
        #expect(report.failures.isEmpty)
        #expect(report.processed.count == items.count)
        #expect(fm.fileExists(atPath: cache.path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent(".Trash/old.txt").path))
    }
}

import AppKit

enum NSWorkspaceRunning {
    static var mail: Bool { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty == false }
}
