import AppIntents

/// Siri and Spotlight phrases. Each phrase must contain the app name.
struct VibeCleanerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: UninstallAppIntent(),
                    phrases: ["Désinstaller \(\.$app) avec \(.applicationName)", "Supprimer \(\.$app) avec \(.applicationName)",
                              "Désinstaller une application avec \(.applicationName)"],
                    shortTitle: "Désinstaller une app", systemImageName: "app.dashed")
        AppShortcut(intent: RunVibeCheckIntent(),
                    phrases: ["Lancer Vibe Check avec \(.applicationName)", "Analyser mon Mac avec \(.applicationName)"],
                    shortTitle: "Lancer Vibe Check", systemImageName: "laptopcomputer")
        AppShortcut(intent: GetMacHealthIntent(),
                    phrases: ["Santé du Mac avec \(.applicationName)", "Comment va mon Mac selon \(.applicationName)"],
                    shortTitle: "Santé du Mac", systemImageName: "heart.text.square")
        AppShortcut(intent: GetStorageStatusIntent(),
                    phrases: ["État du stockage avec \(.applicationName)", "Espace libre avec \(.applicationName)"],
                    shortTitle: "État du stockage", systemImageName: "internaldrive")
        AppShortcut(intent: EmptyTrashIntent(),
                    phrases: ["Vider la corbeille avec \(.applicationName)"],
                    shortTitle: "Vider la corbeille", systemImageName: "trash")
        AppShortcut(intent: FreeUpRAMIntent(),
                    phrases: ["Libérer la RAM avec \(.applicationName)", "Libérer la mémoire avec \(.applicationName)"],
                    shortTitle: "Libérer la RAM", systemImageName: "memorychip")
    }
}

extension VibeCleanerShortcuts {
    /// Lets Siri and Spotlight know the app names of "Désinstaller <app>": call at launch and after an uninstall.
    static func refresh() {
        updateAppShortcutParameters()
    }
}
