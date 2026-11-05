import SwiftUI
import UserNotifications
import VibeCleanerCore

/// Posts the background alerts while the app runs (no separate daemon): samples once a minute,
/// asks `AlertPolicy` what is due, and handles "Ignorer pour…" and "Vider la corbeille…" from the notification actions.
/// Drive connections are reported when `NSWorkspace` announces the mount. The Vibe Check reminder is also scheduled
/// as a local notification, so it reaches the user while the app is closed.
/// Never asks for the notification authorization (onboarding does): without it, nothing is posted.
@MainActor
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    var openModule: (String) -> Void = { _ in }
    private var task: Task<Void, Never>?
    private let sampler = SystemSampler()
    private var mountObserver: NSObjectProtocol?
    static let category = "vibecleaner.alert"
    static let trashCategory = "vibecleaner.alert.trash"
    /// One-off notifications (threat, scan finished…): no "Ignorer" buttons, they would do nothing.
    static let infoCategory = "vibecleaner.info"
    static let emptyTrashAction = "emptyTrash"
    static let scheduledReminderID = "vibeCheckReminder.scheduled"

    /// UNUserNotificationCenter needs an app bundle; `swift run` has none.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard Self.isAvailable, task == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let actions = SnoozeOption.allCases.map { UNNotificationAction(identifier: "snooze.\($0.rawValue)", title: "Ignorer : \($0.title.lowercased())") }
        let empty = UNNotificationAction(identifier: Self.emptyTrashAction, title: "Vider la corbeille…", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: actions, intentIdentifiers: []),
                                          UNNotificationCategory(identifier: Self.trashCategory, actions: [empty] + actions, intentIdentifiers: []),
                                          UNNotificationCategory(identifier: Self.infoCategory, actions: [], intentIdentifiers: [])])
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.driveMounted(url) }
        }
        task = Task {
            while !Task.isCancelled {
                await evaluate()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Posts a one-off notification (threat found, scan finished…) that opens `module` when clicked.
    /// `kind` is any stable id; it is not snoozable unless it is an `AlertKind` raw value.
    func post(kind: String, title: String, body: String, module: String) async {
        guard Self.isAvailable, await Self.isAuthorized() else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = AlertKind(rawValue: kind) == nil ? Self.infoCategory : Self.category
        content.userInfo = ["kind": kind, "module": module]
        try? await center.add(UNNotificationRequest(identifier: "\(kind).\(UUID().uuidString)", content: content, trigger: nil))
    }

    private func driveMounted(_ url: URL) {
        guard Prefs.monitorAlertSettings(capacity: nil).driveConnected, !AlertStore.load().isSnoozed(.driveConnected),
              let v = ExternalVolume.load(url) else { return }
        Task { await post(kind: AlertKind.driveConnected.rawValue, title: "« \(v.name) » connecté",
                          body: "\(FileSizer.format(v.available)) libres sur \(FileSizer.format(v.total)). Cliquez pour l'explorer dans le Radar.",
                          module: "radar") }
    }

    /// Authorized (or provisional) only; never prompts.
    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    private func evaluate() async {
        let sampler = self.sampler
        let base = Prefs.monitorAlertSettings(capacity: nil)
        // The Trash is only listed when the alert is on and readable, so nothing is read for nothing.
        let watchTrash = base.trashedApps && Permissions.hasFullDiskAccess
        let watchExternal = base.externalLow
        let (snapshot, inputs) = await Task.detached {
            (sampler.sample(), AlertInputs(accessories: PeripheralBattery.read(),
                                           trashedApps: watchTrash ? TrashWatch.find(home: sampler.home) : [], trashWatched: watchTrash,
                                           externalVolumes: watchExternal ? ExternalVolume.mounted() : []))
        }.value
        var state = AlertStore.load()
        state.prune(inputs)
        let settings = Prefs.monitorAlertSettings(capacity: snapshot.disk?.total)
        guard await Self.isAuthorized() else { AlertStore.save(state); return }
        let center = UNUserNotificationCenter.current()
        // A reminder the system already delivered while the app was closed counts as sent.
        if let date = AlertPolicy.reminderDate(settings: settings, state: state),
           let shown = await center.deliveredNotifications().first(where: { $0.request.identifier == Self.scheduledReminderID }),
           shown.date >= date {
            state.markSent(AlertPolicy.reminder(state), now: shown.date)
        }
        let due = AlertPolicy.due(snapshot: snapshot, settings: settings, state: state, inputs: inputs)
        for alert in due {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.categoryIdentifier = alert.kind == .trashFull ? Self.trashCategory : Self.category
            content.userInfo = ["kind": alert.kind.rawValue, "module": alert.module]
            try? await center.add(UNNotificationRequest(identifier: alert.kind.rawValue, content: content, trigger: nil))
            state.markSent(alert)
        }
        AlertStore.save(state)
        await Self.scheduleVibeCheckReminder(state: state, settings: settings)
    }

    /// Replaces the pending Vibe Check reminder by one at the next due date, delivered even when the app is closed.
    /// Two minutes late on purpose: while the app runs, the minute loop posts it first and reschedules.
    static func scheduleVibeCheckReminder(state: AlertState = AlertStore.load(), settings: AlertSettings = Prefs.monitorAlertSettings(capacity: nil)) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [scheduledReminderID])
        guard await isAuthorized(), let date = AlertPolicy.reminderDate(settings: settings, state: state) else { return }
        let alert = AlertPolicy.reminder(state)
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["kind": alert.kind.rawValue, "module": alert.module]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(120, date.timeIntervalSinceNow + 120), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: scheduledReminderID, content: content, trigger: trigger))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let module = info["module"] as? String else { return }
        let kind = (info["kind"] as? String).flatMap(AlertKind.init)
        let action = response.actionIdentifier
        await MainActor.run {
            if action.hasPrefix("snooze."), let kind, let option = SnoozeOption(rawValue: String(action.dropFirst("snooze.".count))) {
                AlertStore.update { $0.snooze(kind, option) }
            } else if action == Self.emptyTrashAction {
                Self.confirmEmptyTrash()
            } else if action == UNNotificationDefaultActionIdentifier {
                openModule(module)
            }
        }
    }
}

extension AlertCenter {
    /// The notification button never empties directly: the same confirmation as the menu comes first, then the result.
    static func confirmEmptyTrash() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Vider définitivement la corbeille ?"
        alert.informativeText = "Les fichiers de la corbeille seront supprimés pour de bon."
        alert.addButton(withTitle: "Vider la corbeille").hasDestructiveAction = true
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let done = NSAlert()
            done.messageText = await MenuActions.emptyTrash()
            done.runModal()
        }
    }
}

/// Alert history and snoozes, kept in the app's defaults.
enum AlertStore {
    static let key = "alertState"

    static func load() -> AlertState {
        if let data = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(AlertState.self, from: data) { return s }
        let s = AlertState(firstLaunch: Date())
        save(s)
        return s
    }

    static func save(_ state: AlertState) {
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: key)
    }

    static func update(_ change: (inout AlertState) -> Void) {
        var s = load()
        change(&s)
        save(s)
    }
}
