import Foundation
import Testing
@testable import VibeCleanerCore

/// Menu, notification and Shortcuts actions (empty Trash, free RAM) and the alerts added with them.
/// Everything runs on a temporary home; `purge` is only exercised in simulation.
@Suite struct QuickActionsTests {
    let home: URL
    var trash: URL { home.appendingPathComponent(".Trash") }

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-trashbin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)))
    }

    func fillTrash() throws {
        try FileManager.default.createDirectory(at: trash.appendingPathComponent("Dossier/sous"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_000).write(to: trash.appendingPathComponent("a.txt"))
        try Data(repeating: 2, count: 8_000).write(to: trash.appendingPathComponent("Dossier/sous/b.bin"))
    }

    var leftInTrash: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted() }

    @Test func simulationTouchesNothingAndSaysSo() throws {
        try fillTrash()
        let remover = SafeRemover(dryRun: true, home: home.path)
        let report = try TrashBin.emptyUserTrash(remover: remover)
        #expect(report.processed.count == 2 && report.failures.isEmpty && report.freedBytes >= 12_000)
        #expect(leftInTrash == ["Dossier", "a.txt"])
        #expect(TrashBin.message(report, dryRun: true).hasPrefix("Mode simulation"))
    }

    @Test func emptiesTheTrashPermanentlyButKeepsTheFolder() throws {
        try fillTrash()
        let report = try TrashBin.emptyUserTrash(remover: SafeRemover(home: home.path))
        #expect(report.outcome == .success && report.processed.count == 2)
        #expect(leftInTrash.isEmpty && FileManager.default.fileExists(atPath: trash.path))
        #expect(TrashBin.message(report, dryRun: false).hasPrefix("Corbeille vidée"))
        #expect(TrashBin.message(try TrashBin.emptyUserTrash(remover: SafeRemover(home: home.path)), dryRun: false) == "La corbeille est déjà vide.")
    }

    @Test func userExclusionsAreHonoured() throws {
        try fillTrash()
        let kept = trash.appendingPathComponent("Dossier").path
        let report = try TrashBin.emptyUserTrash(remover: SafeRemover(userExclusions: [kept], home: home.path))
        #expect(report.outcome == .partial && report.failures.map(\.id) == [kept])
        #expect(leftInTrash == ["Dossier"])
        #expect(TrashBin.message(report, dryRun: false).contains("en partie"))
    }

    @Test func unreadableTrashThrows() {
        #expect(throws: RemovalError.self) { try TrashBin.emptyUserTrash(remover: SafeRemover(dryRun: true, home: home.path)) }
    }

    @Test func purgeIsAnAdminItemAndNeverRunsInSimulation() {
        #expect(MemoryPurge.item.action == .command(executable: "/usr/sbin/purge", arguments: [], admin: true))
        let suite = "vc-purge-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let history = MaintenanceHistory(suiteName: suite)
        let report = MemoryPurge.run(remover: SafeRemover(dryRun: true, home: home.path), history: history)
        #expect(report.processed == [MemoryPurge.item.id] && report.log.isEmpty)
        #expect(history.lastRuns["freeRAM"] == nil)
        #expect(MemoryPurge.message(report, dryRun: true).hasPrefix("Mode simulation"))
    }
}

@Suite struct ExternalAndReminderAlertsTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let snapshot = SystemSnapshot(memory: MemoryUsage(total: 16_000_000_000, app: 4_000_000_000),
                                  disk: DiskUsage(total: 500_000_000_000, available: 200_000_000_000), uptime: 3_600, trashSize: 1)

    var state: AlertState {
        var s = AlertState(firstLaunch: now.addingTimeInterval(-3_600))
        s.lastVibeCheck = now.addingTimeInterval(-86_400)
        return s
    }

    func volume(_ name: String, free: Int64, readOnly: Bool = false) -> ExternalVolume {
        ExternalVolume(url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name, total: 1_000, available: free, isReadOnly: readOnly)
    }

    @Test func externalDiskAlmostFullUnderTenPercent() {
        let inputs = AlertInputs(externalVolumes: [volume("Plein", free: 50), volume("Ok", free: 300), volume("Image", free: 0, readOnly: true)])
        let due = AlertPolicy.due(snapshot: snapshot, settings: AlertSettings(), state: state, inputs: inputs, now: now)
        #expect(due.map(\.kind) == [.externalLow])
        #expect(due.first?.subjects == ["/Volumes/Plein"] && due.first?.module == "radar")
        #expect(due.first?.body.contains("« Plein »") == true && due.first?.body.contains("Ok") == false)
        var off = AlertSettings()
        off.externalLow = false
        #expect(AlertPolicy.due(snapshot: snapshot, settings: off, state: state, inputs: inputs, now: now).isEmpty)
        #expect(AlertPolicy.due(snapshot: snapshot, settings: AlertSettings(), state: state,
                                inputs: AlertInputs(externalVolumes: [volume("Pile", free: 100)]), now: now).isEmpty)
    }

    @Test func reminderDateFollowsLastVibeCheckOrLastReminder() {
        var settings = AlertSettings()
        settings.reminderInterval = 7 * 86_400
        var s = state
        #expect(AlertPolicy.reminderDate(settings: settings, state: s) == s.lastVibeCheck!.addingTimeInterval(7 * 86_400))
        s.markSent(AlertPolicy.reminder(s), now: now)
        #expect(AlertPolicy.reminderDate(settings: settings, state: s) == now.addingTimeInterval(7 * 86_400))
        settings.reminder = false
        #expect(AlertPolicy.reminderDate(settings: settings, state: s) == nil)
    }

    @Test func unwatchedTrashIsForgottenSoNoBurstLater() {
        let app = TrashWatch.App(url: URL(fileURLWithPath: "/tmp/.Trash/A.app"), name: "A", bundleID: "com.example.a", leftovers: [])
        var s = state
        s.trashedAppsSeen = ["/tmp/.Trash/Old.app"]
        s.prune(AlertInputs(trashWatched: false))
        #expect(s.trashedAppsSeen == nil)
        // Access granted later: the first real look only records what is there.
        s.prune(AlertInputs(trashedApps: [app]))
        #expect(AlertPolicy.due(snapshot: snapshot, settings: AlertSettings(), state: s, inputs: AlertInputs(trashedApps: [app]), now: now).isEmpty)
    }
}
