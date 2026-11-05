import CoreWLAN
import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct MonitorGuideTests {
    let gb: Int64 = 1_000_000_000
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func healthy() -> SystemSnapshot {
        SystemSnapshot(memory: MemoryUsage(total: 16 * gb, app: 4 * gb), disk: DiskUsage(total: 500 * gb, available: 200 * gb), uptime: 3_600)
    }

    func facts(scans: [String: Date]?, deep: Date? = nil) -> HealthAssessment.Facts {
        var f = HealthAssessment.Facts()
        f.lastScans = scans
        f.lastDeepScan = deep
        f.now = now
        return f
    }

    func ids(_ f: HealthAssessment.Facts) -> Set<String> { Set(HealthAssessment(snapshot: healthy(), facts: f).issues.map(\.id)) }

    // MARK: SMART

    @Test func driveHealthFromDiskutilText() {
        let text = """
           Media Type:                Generic
           Protocol:                  Apple Fabric
           SMART Status:              Verified
           Volume UUID:               7EDF5FF5
        """
        #expect(DriveHealth.parse(text: text) == .verified)
        #expect(DriveHealth.parse(text: "   SMART Status:   Failing\n") == .failing)
        #expect(DriveHealth.parse(text: "   SMART Status:   Not Supported\n") == .notSupported)
        #expect(DriveHealth.parse(text: "Device Node: /dev/disk3") == .unknown)
    }

    @Test func driveHealthFromDiskutilPlist() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["SMARTStatus": "Failing", "Internal": true], format: .xml, options: 0)
        #expect(DriveHealth.parse(plist: data) == .failing)
        #expect(DriveHealth.parse(plist: Data("garbage".utf8)) == .unknown)
    }

    @Test func failingDriveForcesCritical() {
        var f = HealthAssessment.Facts()
        f.drive = .failing
        let a = HealthAssessment(snapshot: healthy(), facts: f)
        #expect(a.issues.first?.id == "critical_drive_health")
        #expect(a.issues.first?.priority == 1400)
        #expect(a.status == .critical)
        f.drive = .notSupported
        #expect(HealthAssessment(snapshot: healthy(), facts: f).issues.isEmpty)
    }

    // MARK: Factors

    @Test func menuAndMonitorOff() {
        var f = HealthAssessment.Facts()
        f.menuEnabled = false
        f.malwareMonitorEnabled = false
        let a = HealthAssessment(snapshot: healthy(), facts: f)
        #expect(a.issues.map(\.id) == ["disabled_menu", "malware_monitor_off"])
        #expect(a.score == 100 - HealthAssessment.Penalty.menuOff - HealthAssessment.Penalty.monitorOff)
    }

    @Test func noHistoryLeavesRecencyOut() {
        #expect(ids(facts(scans: nil)).isEmpty)
    }

    @Test func neverScannedGroupsUnderVibeCheck() {
        let a = HealthAssessment(snapshot: healthy(), facts: facts(scans: [:]))
        // Vibe Check stands for its modules; Cloud is not part of it.
        #expect(Set(a.issues.map(\.id)) == ["no_vibe_check_recently", "no_cloud_recently", "no_deep_scan_recently"])
        #expect(a.issues.first?.id == "no_deep_scan_recently")
        #expect(a.score == 100 - HealthAssessment.Penalty.noVibeCheck - HealthAssessment.Penalty.noDeepScan)
        #expect(a.issues.first { $0.id == "no_vibe_check_recently" }?.module == "vibecheck")
    }

    @Test func staleModulesAfterRecentVibeCheck() {
        let day: TimeInterval = 86_400
        var scans: [String: Date] = [:]
        for m in HealthAssessment.recencyFactors.map(\.module) { scans[m] = now.addingTimeInterval(-day) }
        scans["vibecheck"] = now.addingTimeInterval(-2 * day)
        scans["junk"] = now.addingTimeInterval(-20 * day)
        let recentDeep = now.addingTimeInterval(-10 * day)
        #expect(ids(facts(scans: scans, deep: recentDeep)) == ["no_cleanup_recently"])
        scans["vibecheck"] = now.addingTimeInterval(-8 * day)
        #expect(ids(facts(scans: scans, deep: recentDeep)) == ["no_vibe_check_recently"])
        var f = facts(scans: scans, deep: now.addingTimeInterval(-31 * day))
        f.vibeCheckInterval = 14 * day
        #expect(ids(f) == ["no_cleanup_recently", "no_deep_scan_recently"])
    }

    // MARK: Guide helpers

    @Test func skipsHideUntilExpiry() {
        var f = facts(scans: nil)
        f.menuEnabled = false
        f.threats = 1
        let issues = HealthAssessment(snapshot: healthy(), facts: f).issues
        let skipped = ["malware_detected": now.addingTimeInterval(3_600)]
        #expect(Guide.visible(issues, skipped: skipped, now: now).map(\.id) == ["disabled_menu"])
        #expect(Guide.today(issues, skipped: skipped, now: now.addingTimeInterval(7_200))?.id == "malware_detected")
    }

    @Test func badgeTakesWorstSeverity() {
        #expect(Guide.badge([]) == nil)
        var f = HealthAssessment.Facts()
        f.unusedApps = 3
        #expect(Guide.badge(HealthAssessment(snapshot: healthy(), facts: f).issues) == nil) // info only
        f.malwareMonitorEnabled = false
        f.toReview = 1
        var b = Guide.badge(HealthAssessment(snapshot: healthy(), facts: f).issues)
        #expect(b?.severity == .warning && b?.count == 2)
        f.threats = 1
        b = Guide.badge(HealthAssessment(snapshot: healthy(), facts: f).issues)
        #expect(b?.severity == .critical && b?.count == 3)
    }

    @Test func everyFactorCanBeSimulated() {
        for id in Guide.factorIDs {
            #expect(Guide.sample(id)?.id == id, "\(id)")
            #expect(!Guide.explanation(id).isEmpty)
        }
        #expect(Guide.sample("nope") == nil)
        let base = HealthAssessment(snapshot: healthy())
        let sim = Guide.simulate(base, forcing: ["malware_detected", "uptime"])
        #expect(sim.issues.map(\.id) == ["malware_detected", "uptime"])
        #expect(sim.status == .critical)
        #expect(base.issues.isEmpty)
    }

    @Test func macModelFromSystemProfiler() {
        let json = #"{"SPHardwareDataType":[{"_name":"hardware_overview","chip_type":"Apple M4 Max","machine_name":"MacBook Pro"}]}"#
        let m = MacModel.parse(systemProfilerJSON: json)
        #expect(m == MacModel(name: "MacBook Pro", chip: "Apple M4 Max"))
        #expect(m?.kind == .laptop)
        #expect(MacModel(name: "Mac Studio").kind == .studio)
        #expect(MacModel(name: "Mac mini").kind == .mini)
        #expect(MacModel(name: "iMac").kind == .imac)
        #expect(MacModel(name: "Mac Pro").kind == .pro)
        #expect(MacModel.parse(systemProfilerJSON: "{}") == nil)
    }

    // MARK: Menu widgets

    @Test func peripheralBatteriesFromRegistry() {
        let services: [[String: Any]] = [
            ["Product": "Magic Keyboard", "BatteryPercent": 15, "DeviceAddress": "aa-bb"],
            ["Product": "Magic Keyboard", "BatteryPercent": 15, "DeviceAddress": "aa-bb"],
            ["Product": "Magic Mouse", "BatteryPercent": NSNumber(value: 80), "SerialNumber": "X1"],
            ["Product": "USB hub"],
            ["Product": "Bad", "BatteryPercent": 140],
        ]
        let d = PeripheralBattery.parse(services)
        #expect(d.map(\.name) == ["Magic Keyboard", "Magic Mouse"])
        #expect(d.first?.symbol == "keyboard")
        #expect(d.last?.id == "X1")
    }

    @Test func externalVolumeFilter() {
        #expect(ExternalVolume.isListed(path: "/Volumes/USB", isInternal: false, isBrowsable: true))
        #expect(ExternalVolume.isListed(path: "/Volumes/NAS", isInternal: nil, isBrowsable: nil))
        #expect(!ExternalVolume.isListed(path: "/", isInternal: false, isBrowsable: true))
        #expect(!ExternalVolume.isListed(path: "/Volumes/Data", isInternal: true, isBrowsable: true))
        #expect(!ExternalVolume.isListed(path: "/Volumes/Hidden", isInternal: false, isBrowsable: false))
    }

    @Test func quitOnlyRegularUserApps() {
        #expect(QuitPolicy.canQuit(bundleID: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", isRegularApp: true, ownBundleID: "me"))
        #expect(!QuitPolicy.canQuit(bundleID: "com.google.Chrome.helper", bundlePath: "/Applications/Google Chrome.app/x/Helper.app", isRegularApp: false, ownBundleID: nil))
        #expect(!QuitPolicy.canQuit(bundleID: "com.apple.finder", bundlePath: "/System/Library/CoreServices/Finder.app", isRegularApp: true, ownBundleID: nil))
        #expect(!QuitPolicy.canQuit(bundleID: "com.apple.dock", bundlePath: "/Applications/Dock.app", isRegularApp: true, ownBundleID: nil))
        #expect(!QuitPolicy.canQuit(bundleID: "me", bundlePath: "/Applications/Vibe Cleaner.app", isRegularApp: true, ownBundleID: "me"))
        #expect(!QuitPolicy.canQuit(bundleID: "x", bundlePath: "/usr/bin/x", isRegularApp: true, ownBundleID: nil))
    }

    @Test func networkKindAndSecurity() {
        #expect(NetworkKind(interface: nil, isWiFi: false) == .offline)
        #expect(NetworkKind(interface: "en0", isWiFi: true) == .wifi)
        #expect(NetworkKind(interface: "en7", isWiFi: false) == .wired)
        #expect(NetworkKind(interface: "utun4", isWiFi: false) == .vpn)
        #expect(NetworkKind(interface: "bridge0", isWiFi: false) == .other)
        #expect(WiFiSecurity(CWSecurity.none).level == .open)
        #expect(WiFiSecurity(CWSecurity.WEP).level == .weak)
        #expect(WiFiSecurity(CWSecurity.wpa2Personal).level == .good)
        #expect(WiFiSecurity(CWSecurity.wpa3Personal).level == .strong)
        #expect(WiFiSecurity(CWSecurity.unknown).level == .unknown)
    }

    @Test func speedTestParsing() {
        let out = #"{"dl_throughput":52000000,"ul_throughput":12000000,"base_rtt":24.5,"responsiveness":900,"interface_name":"en0"}"#
        let r = SpeedTestResult.parse(out)
        #expect(r?.download == 52 && r?.upload == 12 && r?.rtt == 24.5)
        #expect(r?.goodFor.contains("Vidéo en streaming") == true)
        #expect(r?.goodFor.contains("Jeu en ligne") == true)
        #expect(SpeedTestResult(download: 3, upload: 1).goodFor == ["Messagerie", "Appels audio", "Musique en streaming"])
        #expect(SpeedTestResult(download: 12, upload: 1, rtt: 80).goodFor.contains("Jeu en ligne") == false)
        #expect(SpeedTestResult.parse("error") == nil)
        #expect(SpeedTestResult.arguments == ["-c", "-s"])
    }

    @Test func thermalLevels() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.critical) == .critical)
        #expect(ThermalLevel(.serious) > .fair)
    }

    // MARK: Storage and trashed apps (temporary folders only)

    func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ url: URL, bytes: Int = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test func storageBreakdownSumsFoldersAndOther() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home.appendingPathComponent("Desktop/a"))
        try write(home.appendingPathComponent("Downloads/b"))
        let apps = home.appendingPathComponent("Apps")
        try write(apps.appendingPathComponent("X.app/c"))
        let sizes: [String: Int64] = ["Apps": 300, "Applications": 0, "Desktop": 100, "Documents": 0, "Downloads": 50]
        let b = StorageBreakdown.compute(home: home, applications: [apps], used: 1_000) { sizes[$0.lastPathComponent] ?? 0 }
        #expect(b.parts.map(\.title) == ["Apps", "Bureau", "Documents", "Téléchargements", "Autres"])
        #expect(b.parts.map(\.bytes) == [300, 100, 0, 50, 550])
        let real = StorageBreakdown.compute(home: home, applications: [apps], used: 0)
        #expect(real.parts[0].bytes > 0 && real.parts[1].bytes > 0 && real.parts.last?.bytes == 0)
    }

    @Test func trashedAppsWithLeftovers() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func trash(_ name: String, id: String) throws {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name], format: .xml, options: 0)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".Trash/\(name).app/Contents"), withIntermediateDirectories: true)
            try plist.write(to: home.appendingPathComponent(".Trash/\(name).app/Contents/Info.plist"))
        }
        try trash("Foo", id: "com.example.foo")
        try trash("Bar", id: "com.example.bar")
        try trash("Old", id: "com.example.old")
        try write(home.appendingPathComponent("Library/Preferences/com.example.foo.plist"))
        try write(home.appendingPathComponent("Library/Containers/com.example.old/x"))
        let installed = home.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Old.app"), withIntermediateDirectories: true)
        let found = TrashWatch.find(home: home, installedDirs: [])
        #expect(found.map(\.name) == ["Foo"]) // Bar has no leftovers, Old is installed again in ~/Applications
        #expect(found.first?.leftovers.map(\.lastPathComponent) == ["com.example.foo.plist"])
        #expect(TrashWatch.find(home: home.appendingPathComponent("missing")).isEmpty)
    }
}

@Suite struct ProcessGroupingTests {
    @Test func appBundleIsTheOutermostApp() {
        #expect(SystemSampler.appBundle(of: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)")
                == "/Applications/Claude.app")
        #expect(SystemSampler.appBundle(of: "/Applications/Xcode.app") == "/Applications/Xcode.app")
        #expect(SystemSampler.appBundle(of: "/usr/libexec/WindowServer") == nil)
        #expect(SystemSampler.appBundle(of: "/opt/homebrew/bin/node") == nil)
    }

    @Test func helpersCountInTheirApp() {
        let base = "/Applications/Claude.app"
        let list = [ProcessUsage(pid: 10, name: "Claude", path: base + "/Contents/MacOS/Claude", cpuPercent: 5, memory: 100),
                    ProcessUsage(pid: 11, name: "Claude Helper (Renderer)", path: base + "/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
                                 cpuPercent: 20, memory: 300),
                    ProcessUsage(pid: 20, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                                 cpuPercent: 8, memory: 50)]
        let grouped = SystemSampler.groupedByApp(list)
        let claude = try? #require(grouped.first { $0.name == "Claude" })
        #expect(claude?.pid == 10)
        #expect(claude?.cpuPercent == 25 && claude?.memory == 400)
        #expect(claude?.path == base)
        #expect(grouped.contains { $0.name == "WindowServer" && $0.pid == 20 })
        #expect(grouped.count == 2)
    }

    /// Chrome runs its main process from a temporary code-signing copy; it must join the installed app, not show twice.
    @Test func codeSignCloneJoinsTheInstalledApp() {
        let clone = "/private/var/folders/zm/x/X/com.google.Chrome.code_sign_clone/code_sign_clone.zk1HFg/Google Chrome.app.bundle"
        let installed = "/Applications/Google Chrome.app"
        let list = [ProcessUsage(pid: 652, name: "Google Chrome", path: clone + "/Contents/MacOS/Google Chrome", cpuPercent: 27, memory: 800),
                    ProcessUsage(pid: 849, name: "Google Chrome Helper", path: installed + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/155/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                                 cpuPercent: 50, memory: 200)]
        #expect(SystemSampler.appBundle(of: clone + "/Contents/MacOS/Google Chrome") == clone.replacingOccurrences(of: ".app.bundle", with: ".app"))
        let grouped = SystemSampler.groupedByApp(list)
        #expect(grouped.count == 1)
        #expect(grouped.first?.name == "Google Chrome")
        #expect(grouped.first?.pid == 652)
        #expect(grouped.first?.path == installed)
        #expect(grouped.first?.cpuPercent == 77)
    }

    @Test func versionNamedToolsGetTheirToolName() {
        #expect(SystemSampler.displayName("2.1.296", path: "/Users/me/.local/share/claude/versions/2.1.296") == "claude 2.1.296")
        #expect(SystemSampler.displayName("node", path: "/opt/homebrew/bin/node") == "node")
        #expect(SystemSampler.displayName("1.0", path: nil) == "1.0")
    }

    @Test func interpretersShowTheirScript() {
        #expect(SystemSampler.isInterpreter("Python") && SystemSampler.isInterpreter("python3.12") && SystemSampler.isInterpreter("node"))
        #expect(!SystemSampler.isInterpreter("Pythonista") && !SystemSampler.isInterpreter("Safari"))
        #expect(SystemSampler.script(["python3", "-u", "/Users/me/train.py", "--epochs", "3"]) == "train.py")
        #expect(SystemSampler.script(["python3", "-W", "ignore", "-m", "http.server"]) == "-m http.server")
        #expect(SystemSampler.script(["python3", "-c", "print(1)"]) == "-c")
        #expect(SystemSampler.script(["java", "-Xmx2g", "-jar", "/opt/app/server.jar"]) == "server.jar")
        #expect(SystemSampler.script(["python3"]) == nil)
        // Its own command line is always readable.
        #expect(SystemSampler.arguments(pid: ProcessInfo.processInfo.processIdentifier)?.isEmpty == false)
    }

    @Test func interpretersAreNotMergedIntoTheirApp() {
        let app = "/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
        var a = ProcessUsage(pid: 1, name: "Python · train.py", path: app, cpuPercent: 50, memory: 10)
        a.arguments = ["Python", "train.py"]
        var b = ProcessUsage(pid: 2, name: "Python · serve.py", path: app, cpuPercent: 5, memory: 20)
        b.arguments = ["Python", "serve.py"]
        #expect(SystemSampler.groupedByApp([a, b]).map(\.name).sorted() == ["Python · serve.py", "Python · train.py"])
    }

    @Test func sameScriptFoldsIntoOneLine() {
        #expect(SystemSampler.interpreterLabel("python3.12") == "Python" && SystemSampler.interpreterLabel("Python") == "Python")
        #expect(SystemSampler.interpreterLabel("node") == "Node" && SystemSampler.interpreterLabel("php") == "PHP")
        func worker(_ pid: Int32, _ cpu: Double, _ name: String = "Python : exp_decode.py") -> ProcessUsage {
            var u = ProcessUsage(pid: pid, name: name, cpuPercent: cpu, memory: 1_000)
            u.arguments = ["python3", "exp_decode.py", "--rank", "\(pid)"]
            return u
        }
        let chrome = ProcessUsage(pid: 9, name: "Google Chrome", path: "/Applications/Google Chrome.app", cpuPercent: 39, memory: 12)
        let lines = SystemSampler.groupedScripts([worker(1, 33), chrome, worker(2, 51), worker(3, 32), worker(4, 5, "Python : serve.py")])
        let decode = lines.first { $0.name == "Python : exp_decode.py" }
        #expect(lines.count == 3)
        #expect(decode?.members.map(\.pid) == [2, 1, 3])
        #expect(decode?.pids == [2, 1, 3] && decode?.cpuPercent == 116 && decode?.memory == 3_000)
        #expect(lines.first { $0.name == "Python : serve.py" }?.members.isEmpty == true)
        // Only scripts can be stopped from the panel, never an app line nor this process.
        #expect(decode.map { ProcessStopper.canStop($0, ownPID: 999) } == true)
        #expect(decode.map { ProcessStopper.canStop($0, ownPID: 1) } == false)
        #expect(!ProcessStopper.canStop(chrome, ownPID: 999))
    }

    @Test func systemProcessesAreTold() {
        #expect(ProcessUsage(pid: 1, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", cpuPercent: 0, memory: 0).isSystem)
        #expect(ProcessUsage(pid: 1, name: "kernel_task", cpuPercent: 0, memory: 0).isSystem)
        #expect(!ProcessUsage(pid: 1, name: "node", path: "/opt/homebrew/bin/node", cpuPercent: 0, memory: 0).isSystem)
    }
}
