import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct MonitorTests {
    let gb: Int64 = 1_000_000_000

    func healthy() -> SystemSnapshot {
        SystemSnapshot(memory: MemoryUsage(total: 16 * gb, app: 4 * gb, swapTotal: 2 * gb, swapUsed: 1 * gb),
                       disk: DiskUsage(total: 500 * gb, available: 200 * gb),
                       battery: BatteryInfo(percent: 80, cycleCount: 120, healthPercent: 97, temperatureCelsius: 30),
                       uptime: 2 * 86_400, trashSize: gb)
    }

    @Test func healthySnapshotIsExcellent() {
        let a = HealthAssessment(snapshot: healthy())
        #expect(a.score == 100)
        #expect(a.status == .excellent)
        #expect(a.issues.isEmpty)
    }

    @Test func lowDiskByAbsoluteAndByFraction() {
        var s = healthy()
        s.disk = DiskUsage(total: 500 * gb, available: 8 * gb)
        #expect(HealthAssessment(snapshot: s).issues.map(\.id) == ["out_of_disk_space"])
        s.disk = DiskUsage(total: 4000 * gb, available: 150 * gb) // 3.75 %
        let a = HealthAssessment(snapshot: s)
        #expect(a.issues.first?.module == "junk")
        #expect(a.score == 100 - HealthAssessment.Penalty.lowDisk)
        #expect(a.status == .good)
    }

    @Test func criticalBatteryForcesCritical() {
        var s = healthy()
        s.battery = BatteryInfo(percent: 50, healthPercent: 55)
        let a = HealthAssessment(snapshot: s)
        #expect(a.score == 20)
        #expect(a.status == .critical)
        #expect(a.issues.first?.severity == .critical)
        s.battery = BatteryInfo(percent: 50, healthPercent: 90, serviceRecommended: true)
        #expect(HealthAssessment(snapshot: s).issues.map(\.id) == ["critical_battery_health"])
    }

    @Test func memoryPressureRules() {
        var s = healthy()
        s.memory.pressure = .warning
        #expect(HealthAssessment(snapshot: s).issues.isEmpty) // swap at 50 %
        s.memory.swapUsed = 19 * gb / 10
        #expect(HealthAssessment(snapshot: s).issues.map(\.id) == ["low_ram"])
        s.memory = MemoryUsage(total: 16 * gb, pressure: .critical)
        let a = HealthAssessment(snapshot: s)
        #expect(a.issues.first?.severity == .critical)
        #expect(a.issues.first?.module == "performance")
    }

    @Test func combinedIssuesSortedByPriority() {
        var s = healthy()
        s.uptime = 10 * 86_400
        s.trashSize = 6 * gb
        s.disk = DiskUsage(total: 500 * gb, available: 5 * gb)
        s.battery?.temperatureCelsius = 45
        let a = HealthAssessment(snapshot: s)
        #expect(a.issues.map(\.id) == ["out_of_disk_space", "trash_bin_overfill", "uptime", "battery_temperature"])
        #expect(a.score == 70)
        #expect(a.status == .fair)
        #expect(a.issues.first { $0.id == "uptime" }?.detail.contains("10 jours") == true)
    }

    @Test func factsFromPermissionsAndScans() {
        let a = HealthAssessment(snapshot: healthy(), facts: .init(hasFullDiskAccess: false, threats: 2, unusedApps: 3))
        #expect(a.issues.map(\.id) == ["malware_detected", "no_fda", "unused_apps"])
        #expect(a.score == 0)
        #expect(a.issues.first?.module == "protection")
        #expect(HealthAssessment(snapshot: healthy(), facts: .init(unusedApps: 3)).score == 90)
    }

    @Test func itemsToCheckCostTenPointsWhateverTheirNumber() {
        var f = HealthAssessment.Facts()
        f.toReview = 5
        let a = HealthAssessment(snapshot: healthy(), facts: f)
        #expect(a.issues.map(\.id) == ["items_to_review"])
        #expect(a.issues.first?.severity == .warning)
        #expect(a.score == 90)
    }

    @Test func noBatteryNoTrashAccessIsFine() {
        var s = healthy()
        s.battery = nil
        s.trashSize = nil
        s.disk = nil
        #expect(HealthAssessment(snapshot: s).score == 100)
    }

    @Test func statusBoundaries() {
        #expect([100, 90, 89, 75, 74, 50, 49, 25, 24, 0].map(HealthStatus.init(score:))
                == [.excellent, .excellent, .good, .good, .fair, .fair, .poor, .poor, .critical, .critical])
    }

    @Test func batteryHealthLevels() {
        #expect(BatteryInfo(percent: 1, healthPercent: 96).healthLevel == .perfect)
        #expect(BatteryInfo(percent: 1, healthPercent: 85).healthLevel == .normal)
        #expect(BatteryInfo(percent: 1, healthPercent: 65).healthLevel == .warning)
        #expect(BatteryInfo(percent: 1, healthPercent: 59).healthLevel == .critical)
        #expect(BatteryInfo(percent: 1).healthLevel == .unknown)
    }

    @Test func sampleReturnsPlausibleValues() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trash = home.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(count: 100_000).write(to: trash.appendingPathComponent("x.bin"))

        let sampler = SystemSampler(home: home)
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let s = sampler.sample()

        #expect(s.cpu.coreCount > 0)
        #expect((0...100.001).contains(s.cpu.total))
        #expect(s.memory.total > 0 && s.memory.used > 0 && s.memory.used <= s.memory.total)
        #expect(s.memory.wired > 0)
        let disk = try #require(s.disk)
        #expect(disk.total > 0 && disk.available > 0 && disk.available <= disk.total)
        #expect(s.uptime > 0)
        #expect(s.network.bytesInPerSecond >= 0 && s.network.bytesOutPerSecond >= 0)
        #expect((s.trashSize ?? 0) >= 100_000)
        if let b = s.battery { #expect((0...100).contains(b.percent)) }
        _ = HealthAssessment(snapshot: s)
    }

    @Test func topProcessesIncludesSelf() {
        let sampler = SystemSampler(home: FileManager.default.temporaryDirectory)
        let all = sampler.topProcesses(limit: 10_000)
        #expect(!all.isEmpty)
        let me = all.first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        #expect(me != nil && me!.memory > 0)
        #expect(all.allSatisfy { $0.cpuPercent >= 0 })
        let top = sampler.topProcesses(limit: 3, by: .memory)
        #expect(top.count == 3)
        #expect(top[0].memory >= top[1].memory)
    }
}
