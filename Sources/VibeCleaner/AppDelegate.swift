import SwiftUI
import VibeCleanerCore

/// App lifecycle the SwiftUI scenes don't cover: quit confirmation, Dock badge, Dock icon policy
/// and the windowless start when launched as a login item (no separate helper or daemon).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(entries: Registry.entries)
    /// Set when macOS opened the app at login; the first main window is then hidden.
    static var hideFirstWindow = false
    /// The window hosting `RootView`, registered by `MainWindowProbe`; nil once closed.
    static weak var mainWindow: NSWindow?
    private let log = Log("app")

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.applyLogging()
        // Legacy login items and "Open at Login" pass this in the launch event; other launch paths don't.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Self.hideFirstWindow = atLogin
        log.info(atLogin ? "Lancement à la connexion, sans fenêtre" : "Lancement")
        if atLogin && Prefs.flag(Prefs.menuBarEnabled) { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        trackDockBadge()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click with no visible window: shows the hidden one rather than letting SwiftUI create another.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let window = Self.mainWindow else { return true }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = model.runs.values.filter(\.isBusy)
        guard !busy.isEmpty || model.radar.scanning else { return .terminateNow }
        let cleaning = busy.contains { if case .executing = $0.phase { true } else { false } }
        let alert = NSAlert()
        alert.messageText = cleaning ? "Quitter Vibe Cleaner avant la fin du nettoyage ?" : "Quitter Vibe Cleaner avant la fin de l'analyse ?"
        alert.informativeText = cleaning
            ? "Le nettoyage en cours restera incomplet : une partie des éléments ne sera pas traitée."
            : "Tous les résultats de l'analyse en cours seront perdus."
        alert.addButton(withTitle: "Continuer")
        alert.addButton(withTitle: "Quitter quand même")
        NSApp.activate()
        let quit = alert.runModal() == .alertSecondButtonReturn
        log.info(quit ? "Fermeture pendant une tâche" : "Fermeture annulée")
        return quit ? .terminateNow : .terminateCancel
    }

    /// The main window or Settings, not the menu bar panel nor alerts.
    static func isMainWindow(_ w: NSWindow) -> Bool { w.canBecomeMain && !(w is NSPanel) }

    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow, Self.isMainWindow(closing) else { return }
        if closing === Self.mainWindow { Self.mainWindow = nil }
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isMainWindow($0) }
        // Without a Dock icon the app lives in the menu bar; never hide it when that is off too.
        if !others, !Prefs.flag(Prefs.keepDockIcon), Prefs.flag(Prefs.menuBarEnabled) { NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let w = note.object as? NSWindow, Self.isMainWindow(w), NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// Posted on the thread that wrote the defaults, often a background task (Performance history): hops to the main actor
    /// instead of trapping on its isolation check.
    @objc nonisolated private func defaultsChanged(_ note: Notification) { Task { @MainActor in Prefs.applyLogging() } }

    /// Badge only (no animated tile): mean scan progress, or "…" while cleaning.
    private func trackDockBadge() {
        withObservationTracking {
            var fractions: [Double] = []
            var other = model.radar.scanning
            for run in model.runs.values {
                switch run.phase {
                case .scanning(let f, _): fractions.append(f)
                case .executing: other = true
                default: break
                }
            }
            let label: String? = if !fractions.isEmpty {
                "\(Int((fractions.reduce(0, +) / Double(fractions.count) * 100).rounded())) %"
            } else if other { "…" } else { nil }
            if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackDockBadge() }
        }
    }
}

/// Registers the window it lives in as the main window, and hides it when the app was opened at login.
/// A hidden window stays alive (ordered out), so the menu bar, notifications and the Dock can bring it back.
struct MainWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppDelegate.mainWindow = window
            guard AppDelegate.hideFirstWindow else { return }
            AppDelegate.hideFirstWindow = false
            window.alphaValue = 0
            DispatchQueue.main.async {
                window.orderOut(nil)
                window.alphaValue = 1
            }
        }
    }
}
