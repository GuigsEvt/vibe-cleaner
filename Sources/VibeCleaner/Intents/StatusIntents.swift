import AppIntents
import VibeCleanerCore

/// Health score and its issues, as the menu bar computes them.
struct MacHealthReport: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Santé du Mac"

    @Property(title: "Score") var score: Int
    @Property(title: "État") var status: String
    @Property(title: "Problèmes") var problems: [String]

    init() {
        score = 0
        status = ""
        problems = []
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(score)/100 · \(status)", subtitle: "\(problems.isEmpty ? "Aucun problème" : problems.joined(separator: ", "))")
    }
}

struct GetMacHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Santé du Mac"
    static let description = IntentDescription("Renvoie le score de santé du Mac (sur 100), son état et les problèmes détectés.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<MacHealthReport> & ProvidesDialog {
        let snap = SystemSampler().sample()
        let alerts = Prefs.alertSettings(capacity: snap.disk?.total)
        // Same facts as the menu and the Guide (SMART, menu, monitor, scan ages), so the scores match.
        let health = HealthAssessment(snapshot: snap, facts: Prefs.guideFacts(drive: DriveHealth.read()),
                                      lowDiskBytes: alerts.diskThreshold, trashBytes: alerts.trashThreshold)
        let report = MacHealthReport()
        report.score = health.score
        report.status = health.status.title
        report.problems = health.issues.map(\.title)
        let list = health.issues.isEmpty ? "Aucun problème détecté." : health.issues.map { "• \($0.title) : \($0.detail)" }.joined(separator: "\n")
        return .result(value: report, dialog: IntentDialog(stringLiteral: "Santé du Mac : \(health.score)/100 (\(health.status.title)).\n\(list)"))
    }
}

/// Free space of the startup volume (including purgeable space, as Finder counts it).
struct GetStorageStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "État du stockage"
    static let description = IntentDescription("Renvoie l'espace libre du disque de démarrage et sa capacité.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>> & ProvidesDialog {
        guard let d = SystemSampler().sample().disk, d.total > 0 else { throw IntentFailure.failed("Le disque de démarrage n'a pas pu être lu.") }
        let used = Int((1 - d.availableFraction) * 100)
        let text = "\(FileSizer.format(d.available)) libres sur \(FileSizer.format(d.total)) (\(used) % utilisés)."
        return .result(value: Measurement(value: Double(d.available), unit: .bytes), dialog: IntentDialog(stringLiteral: text))
    }
}
