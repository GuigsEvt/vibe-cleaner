import Foundation
import Testing
@testable import VibeCleanerCore

/// Orphan detection decides what is pre-checked in Applications > Leftovers: a false positive selects
/// the data of an installed app. Fake home in a temporary folder; LaunchServices is replaced by a closure.
@Suite struct LeftoversEdgeTests {
    let fm = FileManager.default
    let home: URL
    var lib: URL { home.appendingPathComponent("Library") }
    let old = Date().addingTimeInterval(-90 * 86_400)

    init() throws {
        home = fm.temporaryDirectory.appendingPathComponent("vc-left-edge-\(UUID().uuidString)/home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func touch(_ rel: String, dir: Bool = false, stale: Bool = true, plist: [String: Any]? = nil) throws {
        let url = lib.appendingPathComponent(rel)
        if dir {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try plist.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } ?? Data("x".utf8)
            try data.write(to: url)
        }
        if stale { try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path) }
    }

    func hits(_ installed: [InstalledApp], registered: @escaping (String) -> Bool = { _ in false }) -> [String: Bool] {
        let found = Leftovers.find(home: home, installed: installed, executableDirs: [], isRegistered: registered)
        return Dictionary(uniqueKeysWithValues: found.map { ($0.url.deletingLastPathComponent().lastPathComponent + "/" + $0.url.lastPathComponent, $0.clear) })
    }

    let bar = InstalledApp(url: URL(fileURLWithPath: "/Applications/Bar.app"), bundleID: "com.Foo.Bar", name: "Bar", teamID: "ABCDE12345",
                           appGroups: ["group.com.foo.shared"])

    @Test func caseOfIdsAndExtensionsDoesNotMatter() throws {
        try touch("Preferences/COM.FOO.BAR.PLIST")
        try touch("Preferences/com.gone.App.PLIST")
        #expect(hits([bar]) == ["Preferences/com.gone.App.PLIST": true])
    }

    @Test func nonMatchingExtensionsAndNonReverseDNSNamesAreIgnored() throws {
        try touch("Preferences/com.gone.App.plist.lockfile")
        try touch("Preferences/ByHost", dir: true)
        try touch("Containers/6F9619FF-8B86-D011-B42D-00C04FC964FF", dir: true)
        try touch("Caches/com.gone", dir: true)          // two components only
        try touch("Caches/com..double.dot", dir: true)
        try touch("Caches/c0m.gone.app", dir: true)       // TLD with a digit
        try touch("Caches/com.gone app.x", dir: true)     // space inside a component
        #expect(hits([bar]).isEmpty)
    }

    @Test func groupContainersOfAnInstalledTeamOrGroupAreKept() throws {
        try touch("Group Containers/ABCDE12345.com.anything.else", dir: true)   // same team as Bar
        try touch("Group Containers/group.com.foo.shared", dir: true)           // Bar's app group
        try touch("Group Containers/ZZZZZ99999.com.gone.app", dir: true)        // unknown team
        try touch("Group Containers/K36BKF7T3D.group.com.apple.configurator", dir: true)
        #expect(hits([bar]) == ["Group Containers/ZZZZZ99999.com.gone.app": false]) // never pre-checked
    }

    @Test func helpersAndVendorSiblingsOfInstalledAppsAreKept() throws {
        try touch("Preferences/com.foo.Bar.helper.plist")
        try touch("Preferences/com.foo.office.plist")
        try touch("Caches/com.foo", dir: true)
        #expect(hits([bar]).isEmpty)
    }

    @Test func registeredOrOwnIdsAreNeverOrphans() throws {
        try touch("Preferences/com.elsewhere.App.plist")
        try touch("Preferences/ai.flowpace.vibecleaner.plist")
        try touch("Preferences/com.apple.Safari.plist")
        try touch("Preferences/org.cups.printers.plist")
        #expect(hits([bar], registered: { $0.lowercased().hasPrefix("com.elsewhere") }).isEmpty)
    }

    @Test func freshDataAndNonRegenerableRootsAreListedButNotChecked() throws {
        try touch("Caches/com.gone.fresh", dir: true, stale: false)
        try touch("Application Support/com.gone.data", dir: true)
        try touch("Logs/com.gone.logs", dir: true)
        #expect(hits([bar]) == ["Caches/com.gone.fresh": false, "Application Support/com.gone.data": false, "Logs/com.gone.logs": true])
    }

    @Test func launchAgentsWithAProgramOnDiskAreKept() throws {
        let tool = home.appendingPathComponent("bin/tool")
        try fm.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: tool)
        try touch("LaunchAgents/com.gone.alive.plist", plist: ["Label": "com.gone.alive", "ProgramArguments": [tool.path]])
        try touch("LaunchAgents/com.gone.dead.plist", plist: ["Label": "com.gone.dead", "Program": "/nonexistent/tool"])
        try touch("LaunchAgents/com.gone.unreadable.plist")
        #expect(hits([bar]) == ["LaunchAgents/com.gone.dead.plist": false, "LaunchAgents/com.gone.unreadable.plist": false])
    }

    @Test func symlinkedEntriesAreSkipped() throws {
        try touch("Caches/real.gone.target", dir: true)
        try fm.createSymbolicLink(at: lib.appendingPathComponent("Caches/com.gone.link"), withDestinationURL: lib.appendingPathComponent("Caches/real.gone.target"))
        #expect(hits([bar]).keys.sorted() == ["Caches/real.gone.target"])
    }

    @Test func idHelpers() {
        #expect(Leftovers.isTeamID("ABCDE12345"))
        #expect(!Leftovers.isTeamID("abcde12345"))
        #expect(!Leftovers.isTeamID("ABCDE1234"))
        #expect(!Leftovers.isTeamID("ÉBCDE12345"))
        #expect(Leftovers.ownerID("com.a.b.c.d") == "com.a.b")
        #expect(Leftovers.vendor("com") == "com")
        #expect(!Leftovers.hasExecutable("com.x.ab", in: [URL(fileURLWithPath: "/usr/bin")])) // < 3 letters never matches
    }
}
