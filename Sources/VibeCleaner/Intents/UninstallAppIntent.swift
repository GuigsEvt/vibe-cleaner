import AppIntents
import AppKit
import VibeCleanerCore

/// Moves an app and its associated files to the Trash, as Applications does, after listing what goes.
struct UninstallAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Désinstaller une application"
    static let description = IntentDescription("Affiche les applications installées et désinstalle proprement celle choisie : l'app et ses fichiers associés vont à la Corbeille.",
                                               searchKeywords: ["désinstaller", "supprimer", "effacer", "application", "app"])
    static let openAppWhenRun = false

    @Parameter(title: "Application", description: "L'application à désinstaller")
    var app: InstalledAppEntity

    static var parameterSummary: some ParameterSummary { Summary("Désinstaller \(\.$app)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentBridge.requireOnboarding()
        let context = Prefs.context()
        var module = ApplicationsModule()
        module.fullDiskAccess = Permissions.hasFullDiskAccess
        guard let plan = module.uninstallPlan(for: URL(fileURLWithPath: app.id), context: context) else {
            throw IntentFailure.notRemovable(app.name)
        }
        let bundle = plan.app.url.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == bundle }
        try await requestConfirmation(actionName: .destructive("Désinstaller"), dialog: IntentDialog(stringLiteral: plan.summary(running: running)))
        let report = await module.execute(plan.items, context: context)
        _ = try? CleanupLog(report: report, module: module.id, dryRun: context.dryRun).save()
        if !context.dryRun { VibeCleanerShortcuts.refresh() }
        var text = context.dryRun
            ? "Simulation : \(report.processed.count) élément(s) de « \(plan.app.name) » auraient été traités. Rien n'a été supprimé."
            : "« \(plan.app.name) » désinstallée : \(report.processed.count) élément(s), \(FileSizer.format(report.freedBytes)) libérés."
        if let first = report.failures.first { text += "\n\(report.failures.count) échec(s), dont : \(first.1)" }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}
