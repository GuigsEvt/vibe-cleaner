import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct AlertsTests {
    let gb: Int64 = 1_000_000_000
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func snapshot(free: Int64 = 200, trash: Int64 = 1) -> SystemSnapshot {
        SystemSnapshot(memory: MemoryUsage(total: 16 * gb, app: 4 * gb, swapTotal: 2 * gb, swapUsed: gb),
                       disk: DiskUsage(total: 500 * gb, available: free * gb), uptime: 3_600, trashSize: trash * gb)
    }

    var fresh: AlertState {
        var s = AlertState(firstLaunch: now.addingTimeInterval(-3_600))
        s.lastVibeCheck = now.addingTimeInterval(-86_400)
        return s
    }

    @Test func quietWhenHealthy() {
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: fresh, now: now).isEmpty)
    }

    @Test func diskAndTrashFollowUserThresholds() {
        var settings = AlertSettings()
        let s = snapshot(free: 8, trash: 3)
        #expect(AlertPolicy.due(snapshot: s, settings: settings, state: fresh, now: now).map(\.kind) == [.lowDisk, .trashFull])
        settings.diskThreshold = 5 * gb
        settings.trashThreshold = 5 * gb
        #expect(AlertPolicy.due(snapshot: s, settings: settings, state: fresh, now: now).isEmpty)
        settings.diskThreshold = 10 * gb
        settings.trashThreshold = 2 * gb
        settings.lowDisk = false
        #expect(AlertPolicy.due(snapshot: s, settings: settings, state: fresh, now: now).map(\.kind) == [.trashFull])
    }

    @Test func lowRAMOnCriticalPressure() {
        var s = snapshot()
        s.memory.pressure = .critical
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: fresh, now: now).map(\.kind) == [.lowRAM])
    }

    @Test func snoozeAndCooldown() {
        let s = snapshot(free: 1)
        var state = fresh
        state.lastSent[.lowDisk] = now.addingTimeInterval(-600)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: state, now: now).isEmpty)
        state.lastSent[.lowDisk] = now.addingTimeInterval(-4_000)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: state, now: now).count == 1)
        state.snooze(.lowDisk, .threeDays, now: now)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: state, now: now.addingTimeInterval(2 * 86_400)).isEmpty)
        #expect(AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: state, now: now.addingTimeInterval(4 * 86_400)).count == 1)
        state.snooze(.lowDisk, .forever, now: now)
        #expect(!AlertPolicy.due(snapshot: s, settings: AlertSettings(), state: state, now: now.addingTimeInterval(400 * 86_400)).contains { $0.kind == .lowDisk })
    }

    @Test func untilTomorrowEndsAtMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Paris")!
        let d = SnoozeOption.untilTomorrow.until(from: now, calendar: cal)
        #expect(cal.component(.hour, from: d) == 0)
        #expect(d > now && d.timeIntervalSince(now) <= 86_400)
    }

    @Test func reminderAfterInterval() {
        var state = fresh
        state.lastVibeCheck = now.addingTimeInterval(-8 * 86_400)
        let due = AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, now: now)
        #expect(due.map(\.kind) == [.vibeCheckReminder])
        state.lastSent[.vibeCheckReminder] = now
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, now: now.addingTimeInterval(86_400)).isEmpty)
        // Never ran: counted from the first launch.
        state = AlertState(firstLaunch: now.addingTimeInterval(-7 * 86_400))
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, now: now).first?.body == "Vous n'avez pas encore lancé Vibe Check.")
    }

    @Test func defaultDiskThresholdIsClosestToTenPercent() {
        #expect(AlertSettings.defaultDiskThreshold(capacity: 500 * gb) == 50 * gb)
        #expect(AlertSettings.defaultDiskThreshold(capacity: 250 * gb) == 20 * gb)
        #expect(AlertSettings.defaultDiskThreshold(capacity: nil) == 100 * gb)
    }

    @Test func healthUsesUserThresholds() {
        let s = snapshot(free: 30, trash: 3)
        #expect(HealthAssessment(snapshot: s).issues.isEmpty)
        #expect(Set(HealthAssessment(snapshot: s, lowDiskBytes: 40 * gb, trashBytes: 2 * gb).issues.map(\.id)) == ["out_of_disk_space", "trash_bin_overfill"])
    }

    func app(_ name: String) -> TrashWatch.App {
        TrashWatch.App(url: URL(fileURLWithPath: "/tmp/.Trash/\(name).app"), name: name, bundleID: "com.example.\(name)", leftovers: [])
    }

    @Test func trashedAppsOnlyAfterFirstLook() {
        var state = fresh
        let first = AlertInputs(trashedApps: [app("Old")])
        state.prune(first)
        #expect(state.trashedAppsSeen == ["/tmp/.Trash/Old.app"])
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, inputs: first, now: now).isEmpty)
        let later = AlertInputs(trashedApps: [app("Old"), app("Foo")])
        state.prune(later)
        let due = AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, inputs: later, now: now)
        #expect(due.map(\.kind) == [.trashedApp])
        #expect(due.first?.subjects == ["/tmp/.Trash/Foo.app"])
        #expect(due.first?.module == "applications")
        state.markSent(due[0], now: now)
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, inputs: later, now: now.addingTimeInterval(7_200)).isEmpty)
        // Emptied from the Trash: forgotten.
        state.prune(AlertInputs())
        #expect(state.trashedAppsSeen == [])
        var off = AlertSettings()
        off.trashedApps = false
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: off, state: state, inputs: later, now: now.addingTimeInterval(7_200)).isEmpty)
    }

    @Test func accessoryBatteryPostponedUntilChargedOrADay() {
        var state = fresh
        let low = AlertInputs(accessories: [PeripheralBattery(id: "kb", name: "Magic Keyboard", percent: 12),
                                            PeripheralBattery(id: "m", name: "Magic Mouse", percent: 60)])
        let due = AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, inputs: low, now: now)
        #expect(due.map(\.kind) == [.accessoryBattery])
        #expect(due.first?.body == "Magic Keyboard : 12 %")
        state.markSent(due[0], now: now)
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, inputs: low, now: now.addingTimeInterval(7_200)).isEmpty)
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, inputs: low, now: now.addingTimeInterval(86_400)).count == 1)
        // Charged to 50 % then low again: alerted again without waiting a day.
        state.prune(AlertInputs(accessories: [PeripheralBattery(id: "kb", name: "Magic Keyboard", percent: 55)]))
        #expect(state.accessoriesNotified?["kb"] == nil)
        #expect(AlertPolicy.due(snapshot: snapshot(), settings: AlertSettings(), state: state, inputs: low, now: now.addingTimeInterval(7_200)).count == 1)
    }

    @Test func oldSavedStateStillDecodes() throws {
        let old = #"{"snoozedUntil":[],"lastSent":[],"firstLaunch":0}"#
        let s = try JSONDecoder().decode(AlertState.self, from: Data(old.utf8))
        #expect(s.trashedAppsSeen == nil && s.accessoriesNotified == nil)
        #expect(!s.isSnoozed(.driveConnected))
    }
}
