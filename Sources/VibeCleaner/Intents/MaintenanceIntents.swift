import AppIntents
import VibeCleanerCore

/// Opens Vibe Cleaner on Vibe Check and starts the scan. Nothing is cleaned: the user reviews and runs it in the app.
struct RunVibeCheckIntent: AppIntent {
    static let title: LocalizedStringResource = "Lancer Vibe Check"
    static let description = IntentDescription("Ouvre Vibe Cleaner sur Vibe Check et lance l'analyse. Rien n'est nettoyé sans votre validation dans l'app.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = IntentBridge.model, let run = model.runs["vibecheck"] else { throw IntentFailure.appNotReady }
        model.show("vibecheck")
        switch run.phase {
        case .intro, .summary:
            // Same entry point as the round button: single-scan lock, "all modules off" alert.
            run.requestScan()
            guard run.isScanning else { return .result(dialog: "L'analyse n'a pas été lancée : voyez le message dans Vibe Cleaner.") }
            return .result(dialog: "Analyse Vibe Check lancée. Vérifiez les résultats dans Vibe Cleaner avant de nettoyer.")
        case .results:
            return .result(dialog: "Des résultats Vibe Check attendent votre revue dans Vibe Cleaner : ils n'ont pas été remplacés.")
        case .scanning, .executing:
            return .result(dialog: "Vibe Check est déjà en cours dans Vibe Cleaner.")
        }
    }
}

/// Empties the user's Trash as the menu bar button does (`TrashBin`, simulation honoured), after an explicit confirmation.
struct EmptyTrashIntent: AppIntent {
    static let title: LocalizedStringResource = "Vider la corbeille"
    static let description = IntentDescription("Supprime définitivement le contenu de la corbeille, après confirmation.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentBridge.requireOnboarding()
        let size = SystemSampler().sample().trashSize
        let what = size.map { "Les \(FileSizer.format($0)) de la corbeille" } ?? "Les fichiers de la corbeille"
        try await requestConfirmation(actionName: .destructive("Vider la corbeille"),
                                      dialog: "\(what) seront supprimés pour de bon. Vider la corbeille ?")
        let remover = Prefs.context().remover
        let report: ExecutionReport
        do { report = try TrashBin.emptyUserTrash(remover: remover) } catch { throw IntentFailure.failed(TrashBin.unreadable) }
        let text = TrashBin.message(report, dryRun: remover.dryRun)
        guard remover.dryRun || report.outcome != .failure else { throw IntentFailure.failed(text) }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// Purges inactive memory as root through `ActionExecutor` (`MemoryPurge`); the admin password prompt appears
/// when the user runs the action, never in simulation.
struct FreeUpRAMIntent: AppIntent {
    static let title: LocalizedStringResource = "Libérer la RAM"
    static let description = IntentDescription("Libère la mémoire inactive (purge). Le mot de passe administrateur est demandé.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentBridge.requireOnboarding()
        try await requestConfirmation(actionName: .run, dialog: "Libérer la mémoire inactive ? Le mot de passe administrateur sera demandé.")
        let remover = Prefs.context().remover
        let report = MemoryPurge.run(remover: remover)
        let text = MemoryPurge.message(report, dryRun: remover.dryRun)
        guard remover.dryRun || report.outcome == .success else { throw IntentFailure.failed(text) }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}
