import Foundation

/// Sort keys of the review list: Name, Size, Date, Items Count. Descending except Name.
public enum ResultSort: String, CaseIterable, Identifiable, Sendable {
    case size, name, date, count
    public var id: String { rawValue }

    public var title: String {
        switch self { case .size: "Taille"; case .name: "Nom"; case .date: "Date"; case .count: "Nombre d'éléments" }
    }

    /// `ascending` flips the default order.
    public func sorted(_ groups: [ResultGroup], ascending: Bool) -> [ResultGroup] {
        let s = sorted(groups)
        return ascending ? s.reversed() : s
    }

    public func sorted(_ items: [ResultItem], ascending: Bool) -> [ResultItem] {
        let s = sorted(items)
        return ascending ? s.reversed() : s
    }

    public func sorted(_ groups: [ResultGroup]) -> [ResultGroup] {
        func byName(_ a: ResultGroup, _ b: ResultGroup) -> Bool { a.title.localizedStandardCompare(b.title) == .orderedAscending }
        switch self {
        case .size:
            // Each total walks the whole group: computed once per group, not twice per comparison.
            return groups.map { ($0, $0.totalSize) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : byName($0.0, $1.0) }.map(\.0)
        case .name: return groups.sorted(by: byName)
        case .date:
            return groups.sorted {
                let a = $0.latestDate ?? .distantPast, b = $1.latestDate ?? .distantPast
                return a != b ? a > b : byName($0, $1)
            }
        case .count:
            return groups.map { ($0, $0.allItems.count) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : byName($0.0, $1.0) }.map(\.0)
        }
    }

    /// Items have no count of their own: "Nombre d'éléments" orders them by size.
    public func sorted(_ items: [ResultItem]) -> [ResultItem] {
        func byName(_ a: ResultItem, _ b: ResultItem) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        switch self {
        case .size, .count: return items.sorted { $0.size != $1.size ? $0.size > $1.size : byName($0, $1) }
        case .name: return items.sorted(by: byName)
        case .date:
            return items.sorted {
                let a = $0.date ?? .distantPast, b = $1.date ?? .distantPast
                return a != b ? a > b : byName($0, $1)
            }
        }
    }
}

public extension ResultGroup {
    /// Most recent date among the group's items, nil when none has a date.
    var latestDate: Date? { allItems.compactMap(\.date).max() }
    /// Items a tick on this very group selects: its own actionable items and its subgroups' bulk items.
    /// A non-bulk group is skipped by its parent's or card's box (`bulkItems`), not by its own.
    var tickItems: [ResultItem] { (keepsFirst ? Array(items.dropFirst()) : items).filter(\.isActionable) + groups.flatMap(\.bulkItems) }

    /// True when nothing in the group's own tags contradicts the filters (a missing tag is no contradiction).
    func matches(_ facets: [String: String]) -> Bool {
        facets.allSatisfy { tags[$0.key] == nil || tags[$0.key] == $0.value }
    }

    /// How many entries carry each value of `key`: the tagged subgroups (not looked into), else the tagged items.
    func facetCounts(_ key: String) -> [String: Int] {
        var out: [String: Int] = [:]
        func walk(_ g: ResultGroup) {
            for i in g.items { if let v = i.tags[key] { out[v, default: 0] += 1 } }
            for sub in g.groups { if let v = sub.tags[key] { out[v, default: 0] += 1 } else { walk(sub) } }
        }
        walk(self)
        return out
    }
}

public extension ResultItem {
    func matches(_ facets: [String: String]) -> Bool {
        facets.allSatisfy { tags[$0.key] == nil || tags[$0.key] == $0.value }
    }
}

extension ResultQueries {
    /// Cards opened to pick things one by one: no box nor action on the card, no "Tout sélectionner" in the review.
    /// Removing every app, or every big file, at once is too serious to be one click away.
    /// What a fresh scan starts with, for the app and the CLI alike: each card's smart choice, except on the cards
    /// picked one by one, which start empty.
    public static func initialSelection(_ groups: [ResultGroup]) -> Set<String> {
        groups.filter { !oneByOneGroupIDs.contains($0.id) }.reduce(into: Set<String>()) { $0.formUnion($1.defaultSelection) }
    }

    public static let oneByOneGroupIDs: Set<String> = ApplicationsModule.uninstallGroupIDs
        .union(["clutter.duplicates", "clutter.similar", "clutter.large", "clutter.downloads"])
}

/// "Afficher" filter of the review list.
public enum ResultFilter: String, CaseIterable, Identifiable, Sendable {
    case all, selected, unselected
    public var id: String { rawValue }

    public var title: String {
        switch self { case .all: "Tout"; case .selected: "Sélectionnés"; case .unselected: "Non sélectionnés" }
    }

    public func matches(_ item: ResultItem, _ selection: Set<String>) -> Bool {
        switch self {
        case .all: true
        case .selected: selection.contains(item.id)
        case .unselected: !selection.contains(item.id)
        }
    }
}

/// Quick selections "Plus gros / Plus petits / Plus récents / Plus anciens".
/// Picks the quarter of the actionable items (rounded up, at least one)
/// at that end of the order, and deselects the rest of the scope. Undated items are never picked by date.
public enum QuickSelection: String, CaseIterable, Identifiable, Sendable {
    case largest, smallest, newest, oldest
    public var id: String { rawValue }
    public static let share = 0.25

    public var title: String {
        switch self { case .largest: "Plus gros"; case .smallest: "Plus petits"; case .newest: "Plus récents"; case .oldest: "Plus anciens" }
    }

    public func pick(_ items: [ResultItem]) -> Set<String> {
        var seen = Set<String>()
        let candidates = items.filter { $0.action != .none && seen.insert($0.id).inserted }
        let ordered: [ResultItem]
        switch self {
        case .largest: ordered = candidates.sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }
        case .smallest: ordered = candidates.sorted { $0.size != $1.size ? $0.size < $1.size : $0.id < $1.id }
        case .newest: ordered = candidates.filter { $0.date != nil }.sorted { $0.date! != $1.date! ? $0.date! > $1.date! : $0.id < $1.id }
        case .oldest: ordered = candidates.filter { $0.date != nil }.sorted { $0.date! != $1.date! ? $0.date! < $1.date! : $0.id < $1.id }
        }
        guard !ordered.isEmpty else { return [] }
        let n = max(1, Int((Double(candidates.count) * Self.share).rounded(.up)))
        return Set(ordered.prefix(n).map(\.id))
    }
}

public enum ResultQueries {
    /// Removes the items in `ids` and prunes the groups left empty (cleaned or ignored items).
    public static func removing(_ ids: Set<String>, from groups: [ResultGroup]) -> [ResultGroup] {
        guard !ids.isEmpty else { return groups }
        func strip(_ g: ResultGroup) -> ResultGroup {
            var g = g
            g.items.removeAll { ids.contains($0.id) }
            g.groups = g.groups.map(strip)
            return g
        }
        return groups.map { strip($0).pruned() }.filter { !$0.isEmpty }
    }

    /// Known Wi-Fi networks to forget (Protection › Réseaux Wi-Fi connus): nothing is deleted, the title says so.
    static func forgottenNetworks(_ items: [ResultItem]) -> Int {
        items.filter { $0.id.hasPrefix("privacy.wifi.") && $0.isActionable }.count
    }

    /// Title of the review before running: what really happens rather than "Protéger 0 élément(s)".
    public static func reviewTitle(_ items: [ResultItem], action: String) -> String {
        let wifi = forgottenNetworks(items)
        if wifi > 0 && wifi == items.count { return "Oublier \(wifi) réseau\(wifi > 1 ? "x" : "") Wi-Fi ?" }
        let apps = uninstalledApps(items)
        if action == "Désinstaller", apps > 0 {
            return "Désinstaller \(apps) app\(apps > 1 ? "s" : ""), \(FileSizer.format(items.reduce(0) { $0 + $1.size })) ?"
        }
        return "\(action) \(items.count) élément(s), \(FileSizer.format(items.reduce(0) { $0 + $1.size })) ?"
    }

    /// App bundles among the items: Applications ids are the bundle path, their files "<bundle>|<file>".
    static func uninstalledApps(_ items: [ResultItem]) -> Int {
        items.filter { !$0.id.contains("|") && $0.id.hasSuffix(".app") }.count
    }

    /// Extra line of the review: what an uninstall takes along, or the Wi-Fi networks forgotten with other items.
    public static func reviewNote(_ items: [ResultItem]) -> String? {
        let apps = uninstalledApps(items), files = items.filter { $0.id.contains("|") }.count
        if apps > 0 {
            return files > 0 ? "Avec \(files) fichier\(files > 1 ? "s" : "") associé\(files > 1 ? "s" : "") : préférences, caches, données et agents de lancement."
                : "Aucun fichier associé n'a été trouvé en dehors de l'app."
        }
        let wifi = forgottenNetworks(items)
        guard wifi > 0 else { return nil }
        if wifi == items.count { return "Il faudra ressaisir leur mot de passe pour s'y reconnecter." }
        return "Dont \(wifi) réseau\(wifi > 1 ? "x" : "") Wi-Fi à oublier : il faudra ressaisir leur mot de passe pour s'y reconnecter."
    }

    /// Items that ask for the administrator password (root batch, admin module actions).
    public static func adminItems(_ items: [ResultItem]) -> [ResultItem] {
        items.filter(\.needsAdmin)
    }

    /// What each module runs, aligned with `modules`: every selected actionable item once, in one module only.
    /// The same item can be found by several modules (a removed app's cache in Nettoyage and Applications › Restes);
    /// it goes to `preferred` (the card under review) when that module has it, otherwise to the module whose action
    /// is the least destructive (Trash or quarantine before permanent, no password before admin), then the first one.
    public static func assignJobs(_ modules: [(id: String, items: [ResultItem])], selection: Set<String>,
                                  preferred: String?) -> [[ResultItem]] {
        var owner: [String: (rank: (Int, Int, Int, Int), module: Int)] = [:]
        for (m, module) in modules.enumerated() {
            for item in module.items where item.isActionable && selection.contains(item.id) {
                let rank = (module.id == preferred ? 0 : 1, item.isIrreversible ? 1 : 0, item.needsAdmin ? 1 : 0, m)
                if let o = owner[item.id], o.rank <= rank { continue }
                owner[item.id] = (rank, m)
            }
        }
        return modules.enumerated().map { m, module in
            var seen = Set<String>()
            return module.items.filter { owner[$0.id]?.module == m && seen.insert($0.id).inserted }
        }
    }

    /// State of a box that ticks `tick` among `all` (a card, a group): on when every ticked item is selected,
    /// off when no actionable item is. Without bulk items, the actionable items decide.
    public static func boxState(tick: [ResultItem], all: [ResultItem], selection: Set<String>) -> SelectionState {
        let actionable = all.filter(\.isActionable)
        guard actionable.contains(where: { selection.contains($0.id) }) else { return .off }
        return (tick.isEmpty ? actionable : tick).allSatisfy { selection.contains($0.id) } ? .on : .mixed
    }

    /// A click on that box: a checked box unticks everything it covers, otherwise it ticks `tick`.
    public static func toggling(tick: [ResultItem], all: [ResultItem], selection: Set<String>) -> Set<String> {
        boxState(tick: tick, all: all, selection: selection) == .on ? selection.subtracting(all.map(\.id))
                                                                     : selection.union(tick.map(\.id))
    }

    /// Group id prefixes of sets where at least one copy must stay (exact duplicates, similar images).
    public static let copySetPrefixes = ["clutter.dup.", "clutter.sim."]

    /// Copy sets whose every item is selected: cleaning them would remove all the copies.
    public static func fullySelectedCopySets(_ groups: [ResultGroup], selection: Set<String>) -> [ResultGroup] {
        groups.flatMap { g -> [ResultGroup] in
            if copySetPrefixes.contains(where: g.id.hasPrefix) {
                return !g.allItems.isEmpty && g.selectionState(selection) == .on ? [g] : []
            }
            return fullySelectedCopySets(g.groups, selection: selection)
        }
    }
}

/// Vibe Check remembers per card what the user unchecked. Only deselections are
/// kept: an item the user once checked by hand is never re-checked automatically. Confirmed threats
/// (`ProtectionModule.confirmedGroupIDs`) always come back checked.
public struct SelectionMemory: Codable, Equatable, Sendable {
    /// Module id → default-selected item ids the user unchecked.
    public var deselected: [String: [String]] = [:]
    /// Modules whose card was entirely unchecked.
    public var cardsOff: Set<String> = []
    public static let limit = 2_000

    public init() {}

    /// Records the choice made on these modules' results; other modules keep their memory.
    /// `accepted` (risks the user accepted) left the selection without being unchecked: not recorded.
    public mutating func capture(_ results: [(module: String, groups: [ResultGroup])], selection: Set<String>,
                                 accepted: Set<String> = []) {
        for r in results {
            let defaults = r.groups.reduce(into: Set<String>()) { $0.formUnion($1.defaultSelection) }
            let picked = r.groups.flatMap(\.allItems).contains { selection.contains($0.id) }
            if !defaults.isEmpty && !picked { cardsOff.insert(r.module) } else { cardsOff.remove(r.module) }
            let off = defaults.subtracting(selection).subtracting(accepted).sorted().prefix(Self.limit)
            deselected[r.module] = off.isEmpty ? nil : Array(off)
        }
    }

    /// Default selection of these results with the remembered choices applied.
    public func selection(for results: [(module: String, groups: [ResultGroup])]) -> Set<String> {
        results.reduce(into: Set<String>()) { sel, r in
            sel.formUnion(Self.confirmedThreats(r.groups))
            guard !cardsOff.contains(r.module) else { return }
            let defaults = r.groups.reduce(into: Set<String>()) { $0.formUnion($1.defaultSelection) }
            sel.formUnion(defaults.subtracting(deselected[r.module] ?? []))
        }
    }

    /// Default selection of the confirmed threat groups, at any depth.
    static func confirmedThreats(_ groups: [ResultGroup]) -> Set<String> {
        groups.reduce(into: Set<String>()) {
            $0.formUnion(ProtectionModule.confirmedGroupIDs.contains($1.id) ? $1.defaultSelection : confirmedThreats($1.groups))
        }
    }

    public static func load(key: String, in defaults: UserDefaults = .standard) -> SelectionMemory {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SelectionMemory.self, from: $0) } ?? SelectionMemory()
    }

    public func save(key: String, in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: key)
    }
}
