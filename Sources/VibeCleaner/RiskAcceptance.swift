import Foundation

/// Protection items whose risk the user accepted ("J'accepte ce risque"): scans still list them, marked,
/// but they are never pre-selected and leave the health score. Undone from the same row.
@MainActor @Observable
final class RiskAcceptance {
    static let shared = RiskAcceptance()
    nonisolated static let key = "acceptedRisks"

    private(set) var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func set(_ items: some Sequence<String>, accepted: Bool) {
        if accepted { ids.formUnion(items) } else { ids.subtract(items) }
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }

    /// Read outside the main actor (health facts).
    nonisolated static var stored: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
}
