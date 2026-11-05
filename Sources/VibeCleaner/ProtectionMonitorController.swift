import Foundation
import VibeCleanerCore

/// Real-time monitor and daily background scan, while the app runs (no separate daemon).
/// New threats raise a "threat" notification that opens Protection, and count in the health score.
@MainActor
final class ProtectionMonitorController {
    static let shared = ProtectionMonitorController()
    private var alerts: AlertCenter?
    private var watcher: DirectoryWatcher?
    private var loop: Task<Void, Never>?
    private var notified: Set<String> = []
    static let backgroundInterval: TimeInterval = 24 * 3600

    func start(alerts: AlertCenter) {
        guard loop == nil else { return }
        self.alerts = alerts
        loop = Task {
            while !Task.isCancelled {
                syncWatcher()
                await backgroundScanIfDue()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// LaunchAgents are always watched; Downloads only with Full Disk Access, which avoids a permission prompt.
    private func watchedFolders() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var dirs = [home.appendingPathComponent("Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"),
                    URL(fileURLWithPath: "/Library/LaunchDaemons")]
        if Permissions.hasFullDiskAccess { dirs.append(home.appendingPathComponent("Downloads")) }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func syncWatcher() {
        let dirs = Prefs.protectionFlag(Prefs.protectionMonitorEnabled) ? watchedFolders() : []
        guard dirs != watcher?.directories ?? [] else { return }
        watcher?.stop()
        watcher = nil
        guard !dirs.isEmpty else { return }
        let w = DirectoryWatcher(directories: dirs) { urls in
            Task { @MainActor in await ProtectionMonitorController.shared.inspect(urls) }
        }
        w.start()
        watcher = w
    }

    private static func module() -> ProtectionModule {
        var m = ProtectionModule()
        Prefs.configureProtection(&m, customScan: false)
        m.includePrivacy = false
        return m
    }

    private func inspect(_ urls: [URL]) async {
        let m = Self.module(), context = Prefs.context()
        let found = await Task.detached { m.assess(urls, context: context) }.value
        await notify(confirmed: found.confirmed, review: found.review)
    }

    private func backgroundScanIfDue() async {
        let d = UserDefaults.standard
        guard Prefs.protectionFlag(Prefs.protectionBackgroundScan) else { return }
        // The first scan waits a day after the first launch, so it never competes with the user's first scan.
        guard let last = d.object(forKey: Prefs.protectionLastBackgroundScan) as? Date else {
            d.set(Date(), forKey: Prefs.protectionLastBackgroundScan)
            return
        }
        guard Date().timeIntervalSince(last) >= Self.backgroundInterval else { return }
        d.set(Date(), forKey: Prefs.protectionLastBackgroundScan)
        var m = Self.module()
        m.depth = .quick
        let context = Prefs.context()
        let groups = await Task.detached { await m.scan(context: context) { _, _ in } }.value
        func items(_ ids: Set<String>) -> [ResultItem] { groups.filter { ids.contains($0.id) }.flatMap(\.allItems) }
        await notify(confirmed: items(ProtectionModule.confirmedGroupIDs), review: items(ProtectionModule.reviewGroupIDs))
    }

    /// Sure threats and items to check are kept apart: only the first ones are called threats and weigh 100 points.
    /// Items whose risk was accepted are neither counted again nor notified.
    private func notify(confirmed: [ResultItem], review: [ResultItem]) async {
        let accepted = RiskAcceptance.shared.ids
        let threats = confirmed.filter { !notified.contains($0.id) }
        let toCheck = review.filter { !notified.contains($0.id) && !accepted.contains($0.id) }
        guard !threats.isEmpty || !toCheck.isEmpty, let alerts else { return }
        notified.formUnion((threats + toCheck).map(\.id))
        let d = UserDefaults.standard
        for (key, new) in [(Prefs.threatIDs, threats), (Prefs.reviewIDs, toCheck)] where !new.isEmpty {
            d.set(Array(Set(d.stringArray(forKey: key) ?? []).union(new.map(\.id))), forKey: key)
        }
        let fresh = threats.isEmpty ? toCheck : threats
        await alerts.post(kind: "threat", title: threats.isEmpty ? "Élément à vérifier dans Protection" : "Vibe Cleaner a détecté une menace",
                          body: ThreatNotice.body(fresh), module: "protection")
    }
}
