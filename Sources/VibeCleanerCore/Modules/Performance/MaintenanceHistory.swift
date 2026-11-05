import Foundation

/// What Performance remembers between runs: last run date of each maintenance task
/// and the login items it disabled. Stored in `UserDefaults`; tests pass their own suite.
public struct MaintenanceHistory: Sendable {
    public var suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    static let lastRunKey = "performanceLastRun"
    static let disabledLoginItemsKey = "performanceDisabledLoginItems"
    static let hiddenLoginItemsKey = "performanceHiddenLoginItems"

    var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// Task key ("flushDNS", "freeRAM"…) → last successful run.
    public var lastRuns: [String: Date] {
        (defaults.dictionary(forKey: Self.lastRunKey) as? [String: Double] ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
    }

    public func record(_ tasks: [String], at date: Date = Date()) {
        guard !tasks.isEmpty else { return }
        var all = defaults.dictionary(forKey: Self.lastRunKey) as? [String: Double] ?? [:]
        for t in tasks { all[t] = date.timeIntervalSince1970 }
        defaults.set(all, forKey: Self.lastRunKey)
    }

    /// Paths of login items removed by "Désactiver", so they can be added back.
    public var disabledLoginItems: [String] { defaults.stringArray(forKey: Self.disabledLoginItemsKey) ?? [] }

    /// The disabled ones that were hidden ("Masquer"), added back hidden.
    public var hiddenLoginItems: Set<String> { Set(defaults.stringArray(forKey: Self.hiddenLoginItemsKey) ?? []) }

    public func setLoginItem(_ path: String, disabled: Bool, hidden: Bool = false) {
        var list = disabledLoginItems.filter { $0 != path }
        if disabled { list.append(path) }
        defaults.set(list, forKey: Self.disabledLoginItemsKey)
        var hiddenList = hiddenLoginItems.subtracting([path])
        if disabled && hidden { hiddenList.insert(path) }
        defaults.set(hiddenList.sorted(), forKey: Self.hiddenLoginItemsKey)
    }
}
