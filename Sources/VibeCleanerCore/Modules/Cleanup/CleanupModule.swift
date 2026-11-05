import AppKit
import Foundation

/// Junk cleanup: system junk, Mail attachments and trash bins.
/// Regenerable caches and trash bins are removed permanently; everything else goes to the Trash.
public struct CleanupModule: ScanModule {
    public let id = "junk"
    public let title = "Nettoyage"
    public let subtitle = "Supprime les caches, journaux, pièces jointes et autres fichiers inutiles pour récupérer de l'espace."
    public let symbol = "trash"
    public let actionTitle = "Nettoyer"
    /// When false, only the home folder is scanned (no /Library, /private, /Volumes, darwin dirs, xcrun or brew).
    public var scansSystemLocations: Bool
    /// Category labels (from `categories`) turned off in the settings.
    public var disabledCategories: Set<String>

    public init(scansSystemLocations: Bool = true, disabledCategories: Set<String> = []) {
        self.scansSystemLocations = scansSystemLocations
        self.disabledCategories = disabledCategories
    }

    /// Scan categories in scan order; the labels double as the settings identifiers.
    public static var categories: [String] { steps.map(\.0) }

    static let versionKey = "document-version"

    public func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup] {
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.flatMap { [$0.bundleIdentifier, $0.localizedName].compactMap { $0?.lowercased() } })
        }
        let s = JunkScope(context: context, system: scansSystemLocations, running: running)
        let steps = Self.steps.filter { !disabledCategories.contains($0.0) }
        var groups: [ResultGroup] = []
        for (i, (label, run)) in steps.enumerated() {
            if Task.isCancelled { break }
            progress(Double(i) / Double(steps.count), label)
            if let g = run(s) { groups.append(g) }
        }
        progress(1, "Terminé")
        return groups
    }

    static var steps: [(String, (JunkScope) -> ResultGroup?)] {
        [
            ("Caches utilisateur", CacheScanner.userCaches),
            ("Caches système", CacheScanner.systemCaches),
            ("Caches de développement", CacheScanner.developerCaches),
            ("Journaux utilisateur", LogScanner.userLogs),
            ("Journaux système", LogScanner.systemLogs),
            ("Fichiers temporaires", CacheScanner.temporaryFiles),
            ("Xcode", XcodeScanner.scan),
            ("Sauvegardes iOS", SystemJunkScanner.iosBackups),
            ("Versions de documents", SystemJunkScanner.documentVersions),
            ("Préférences cassées", SystemJunkScanner.brokenPreferences),
            ("Éléments de démarrage cassés", SystemJunkScanner.brokenLaunchAgents),
            ("Fichiers de langue", AppBundleScanner.languages),
            ("Téléchargements Slack", MailTrashScanner.slackDownloads),
            ("Utilisateurs supprimés", SystemJunkScanner.deletedUsers),
            ("Pièces jointes Mail", MailTrashScanner.mail),
            ("Corbeilles", MailTrashScanner.trash),
        ]
    }

    public func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport {
        // Admin commands that carry a scanned path (broken /Library agents) are revalidated by the executor,
        // and so is every deletion against the modification date seen by the scan.
        var report = ActionExecutor(remover: context.remover, revalidatesModificationDate: true).run(items) { item, key in
            switch key {
            case SystemJunkScanner.loginItemKey:
                if !LoginItems.remove(name: item.name, url: item.url) {
                    throw RemovalError.failed(item.name, "élément de connexion introuvable")
                }
            case Self.versionKey:
                guard let doc = item.url, let date = item.date else { throw RemovalError.failed(item.name, "action non prise en charge") }
                try context.remover.check(doc)
                guard let version = NSFileVersion.otherVersionsOfItem(at: doc)?.first(where: { $0.modificationDate == date }) else {
                    throw RemovalError.failed(doc.path, "version introuvable")
                }
                try version.remove()
            default:
                throw RemovalError.failed(item.name, "action non prise en charge")
            }
        }
        // The executor does not count space freed by user-level commands (brew cleanup, simctl).
        let done = Set(report.processed)
        for item in items where done.contains(item.id) {
            if case .command(_, _, false) = item.action { report.freedBytes += item.size }
        }
        return report
    }

    /// Apps that must be closed first: Mail for its attachments and mailboxes, Xcode and Simulator.
    public func appDependency(of item: ResultItem) -> AppDependency? {
        guard let path = item.url?.path else { return nil }
        if path.contains("/Library/Mail/") || path.contains("/Mail Downloads/") { return AppDependency(name: "Mail", bundleID: "com.apple.mail") }
        if path.contains("/Library/Developer/Xcode/") { return AppDependency(name: "Xcode", bundleID: "com.apple.dt.Xcode") }
        if path.contains("/Library/Developer/CoreSimulator/") { return AppDependency(name: "Simulator", bundleID: "com.apple.iphonesimulator") }
        return nil
    }
}
