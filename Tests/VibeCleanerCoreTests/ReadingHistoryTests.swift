import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct ReadingHistoryTests {
    @Test func keepsOrderBeforeFull() {
        var h = ReadingHistory<Int>(capacity: 4)
        #expect(h.isEmpty)
        #expect(h.last == nil)
        h.append(1); h.append(2); h.append(3)
        #expect(h.values == [1, 2, 3])
        #expect(h.count == 3)
        #expect(h.last == 3)
    }

    @Test func dropsOldestWhenFull() {
        var h = ReadingHistory<Int>(capacity: 3)
        for i in 1...7 { h.append(i) }
        #expect(h.values == [5, 6, 7])
        #expect(h.count == 3)
        #expect(h.last == 7)
    }

    @Test func wrapsExactlyAtCapacity() {
        var h = ReadingHistory<Int>(capacity: 3)
        for i in 1...3 { h.append(i) }
        #expect(h.values == [1, 2, 3])
        h.append(4)
        #expect(h.values == [2, 3, 4])
    }

    @Test func capacityIsAtLeastOne() {
        var h = ReadingHistory<Int>(capacity: 0)
        #expect(h.capacity == 1)
        h.append(1); h.append(2)
        #expect(h.values == [2])
    }

    @Test func removeAllResets() {
        var h = ReadingHistory<Int>(capacity: 2)
        for i in 1...5 { h.append(i) }
        h.removeAll()
        #expect(h.isEmpty)
        h.append(9)
        #expect(h.values == [9])
    }

    @Test func monitorHistoryRecordsSnapshot() {
        var m = MonitorHistory()
        let gb: Int64 = 1_000_000_000
        m.record(SystemSnapshot(cpu: CPUUsage(user: 30, system: 10),
                                memory: MemoryUsage(total: 16 * gb, app: 4 * gb, wired: 2 * gb, compressed: 2 * gb),
                                battery: BatteryInfo(percent: 64),
                                network: NetworkUsage(bytesInPerSecond: 1000, bytesOutPerSecond: 200)))
        #expect(m.cpuTotal == [40])
        #expect(m.memory.values == [50])
        #expect(m.battery.values == [64])
        #expect(m.networkIn.values == [1000])
        #expect(m.networkOut.values == [200])
    }

    @Test func monitorHistorySkipsMissingReadings() {
        var m = MonitorHistory()
        m.record(SystemSnapshot(cpu: CPUUsage(user: 80, system: 40)))
        #expect(m.memory.isEmpty)
        #expect(m.battery.isEmpty)
        #expect(m.cpuTotal == [100])
    }

    @Test func monitorHistoryIsBounded() {
        var m = MonitorHistory()
        for i in 0..<(MonitorHistory.batteryCapacity + 10) {
            m.record(SystemSnapshot(cpu: CPUUsage(user: Double(i % 100)), battery: BatteryInfo(percent: i % 101)))
        }
        #expect(m.cpuUser.count == MonitorHistory.liveCapacity)
        #expect(m.battery.count == MonitorHistory.batteryCapacity)
        #expect(m.cpuUser.last == Double((MonitorHistory.batteryCapacity + 9) % 100))
    }
}
