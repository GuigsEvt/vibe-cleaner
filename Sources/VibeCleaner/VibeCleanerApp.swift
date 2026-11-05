import SwiftUI
import VibeCleanerCore

@main
struct VibeCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.menuBarEnabled) private var menuBarEnabled = true
    private var model: AppModel { delegate.model }

    var body: some Scene {
        // A single main window: `WindowGroup` allowed ⌘N, a second RootView on the same model.
        Window("Vibe Cleaner", id: "main") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Modules") {
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { i, e in
                    Button(e.title) { model.select(e.id) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Le Guide") { model.select("guide") }.keyboardShortcut("0", modifiers: .command)
            }
            CommandMenu("Action") { ActionCommands(model: model) }
            CommandGroup(replacing: .appInfo) { Button("À propos de Vibe Cleaner") { AboutPanel.show() } }
            CommandGroup(replacing: .help) { HelpCommands() }
        }
        Settings { SettingsView().handCursorButtons() }
        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(monitor: model.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reopens the main window if it was closed before bringing a module forward.
private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarView(monitor: model.monitor) { id in
            if AppDelegate.mainWindow == nil { openWindow(id: "main") }
            model.show(id)
        }
    }
}

/// "Action" menu: scan or stop the current module, as its round button does.
private struct ActionCommands: View {
    let model: AppModel

    var body: some View {
        let run = model.current == "radar" ? nil : model.runs[model.current]
        // Same locks and confirmations as the round button.
        Button("Analyser") { run?.requestScan() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(run?.canStartScan ?? false))
        Button("Arrêter l'analyse") {
            if model.current == "radar" { model.radar.stop() } else { run?.stopRequested = true }
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!isScanning(run) && !(model.current == "radar" && model.radar.scanning))
    }

    private func isScanning(_ run: ModuleRun?) -> Bool {
        if case .scanning? = run?.phase { true } else { false }
    }
}

private struct HelpCommands: View {
    @AppStorage(Prefs.extendedLogs) private var extendedLogs = false

    var body: some View {
        Button("À propos de l'accès complet au disque…") { Permissions.explainFullDiskAccess() }
        Divider()
        Toggle("Journaux détaillés", isOn: $extendedLogs)
        Button("Afficher les journaux dans le Finder") { NSWorkspace.shared.open(LogFile.defaultDirectory) }
            .disabled(!FileManager.default.fileExists(atPath: LogFile.defaultDirectory.path))
    }
}
