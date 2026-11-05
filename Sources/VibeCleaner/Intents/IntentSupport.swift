import AppIntents
import VibeCleanerCore

/// The running app's model, for intents that act on the window (set by `AppModel.init`).
@MainActor
enum IntentBridge {
    static weak var model: AppModel?

    /// Actions that change the Mac stay off until the user has opened the app once (onboarding done).
    nonisolated static func requireOnboarding() throws {
        guard UserDefaults.standard.bool(forKey: "onboardingDone") else { throw IntentFailure.notOnboarded }
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notRemovable(String)
    case appNotReady
    case notOnboarded
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRemovable(let name): "« \(name) » ne peut pas être désinstallée (app système, protégée, exclue ou introuvable)."
        case .notOnboarded: "Fonction indisponible : ouvrez d'abord Vibe Cleaner et terminez sa configuration."
        case .appNotReady: "Vibe Cleaner n'est pas prêt. Ouvrez l'app puis réessayez."
        case .failed(let reason): "\(reason)"
        }
    }
}

extension ConfirmationActionName {
    static func destructive(_ label: LocalizedStringResource) -> Self {
        .custom(acceptLabel: label, acceptAlternatives: [], denyLabel: "Annuler", denyAlternatives: [], destructive: true)
    }
}
