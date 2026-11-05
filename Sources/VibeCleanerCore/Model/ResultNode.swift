import Foundation

/// What happens to a selected item when the user runs the module's main action.
public enum ItemAction: Hashable, Sendable {
    /// Remove a file or folder. `admin` items are batched into one administrator prompt.
    case delete(URL, mode: RemovalMode, admin: Bool)
    /// Run a fixed system tool (maintenance tasks, launchctl, tccutil...).
    case command(executable: String, arguments: [String], admin: Bool)
    /// Module-specific action identified by a key, executed by the module itself.
    case custom(String)
    /// Informational row with nothing to execute.
    case none
}

public struct ResultItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var detail: String?
    public var url: URL?
    public var size: Int64
    public var date: Date?
    public var symbol: String?
    public var action: ItemAction
    /// Selected by default after a scan (Smart Selection).
    public var autoSelect: Bool
    /// A `.custom` action that asks for the administrator password when run (delete and command actions say it themselves).
    public var customNeedsAdmin = false
    /// A `.custom` action that cannot be undone (no Trash, no quarantine to restore from).
    public var customIsIrreversible = false
    /// A `.command` with nothing to undo (flushing a cache, rebuilding an index): not marked "Irréversible".
    public var commandIsHarmless = false
    /// Facets the review can filter on, as on `ResultGroup.tags` ("Type" → "Vidéos").
    public var tags: [String: String] = [:]
    /// Every copy of an exact duplicate set this file belongs to, as the scan saw them (the file included).
    /// A deletion needs another copy unselected and unchanged; the set travels with the item, so an older result
    /// never relies on a newer scan, nor a newer one on an older scan.
    public var copySet: [FileCopy] = []

    /// Asks for the administrator password when run: shown in the review before cleaning.
    public var needsAdmin: Bool {
        switch action {
        case .delete(_, _, let admin), .command(_, _, let admin): admin
        case .custom: customNeedsAdmin
        case .none: false
        }
    }
    /// Cannot be undone: permanent removal, system tools, irreversible module actions. Shown as "Irréversible".
    public var isIrreversible: Bool {
        switch action {
        case .delete(_, let mode, _): mode == .permanent
        case .command: !commandIsHarmless
        case .custom: customIsIrreversible
        case .none: false
        }
    }
    /// Informational row, or a link: never selected, counted or run.
    public var isActionable: Bool { action != .none && openLink == nil }
    /// A row that only opens System Settings, the App Store or an app: shown as a button rather than a choice.
    public var openLink: URL? {
        guard case .command("/usr/bin/open", let args, false) = action, args.count == 1 else { return nil }
        let a = args[0]
        if a.hasPrefix("x-apple.systempreferences:") || a.hasPrefix("macappstore:") { return URL(string: a) }
        return a.hasPrefix("/") && a.hasSuffix(".app") ? URL(fileURLWithPath: a) : nil
    }

    public init(id: String? = nil, name: String, detail: String? = nil, url: URL? = nil, size: Int64 = 0,
                date: Date? = nil, symbol: String? = nil, action: ItemAction, autoSelect: Bool = true) {
        self.id = id ?? url?.path ?? name
        self.name = name
        self.detail = detail
        self.url = url
        self.size = size
        self.date = date
        self.symbol = symbol
        self.action = action
        self.autoSelect = autoSelect
    }

    /// Convenience for the common "a file to clean" case.
    public static func file(_ url: URL, size: Int64? = nil, detail: String? = nil, mode: RemovalMode = .trash,
                            admin: Bool = false, autoSelect: Bool = true) -> ResultItem {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return ResultItem(name: url.lastPathComponent, detail: detail ?? url.deletingLastPathComponent().path, url: url,
                          size: size ?? FileSizer.size(of: url), date: values?.contentModificationDate,
                          action: .delete(url, mode: mode, admin: admin), autoSelect: autoSelect)
    }
}

/// One copy of a duplicate set when it was found: length and, for a regular file, modification date.
public struct FileCopy: Hashable, Sendable {
    public let path: String
    public let size: Int64
    public let modified: Date?

    public init(path: String, size: Int64, modified: Date?) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// A category or group of results. Groups nest; leaves are `ResultItem`s.
public struct ResultGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var symbol: String
    public var groups: [ResultGroup]
    public var items: [ResultItem]
    /// When false, nothing in this group is selected by default regardless of item flags.
    public var autoSelect: Bool
    /// When false, ticking a parent group or a whole card leaves this group alone: its items are ticked one by one
    /// (reversible alternatives such as "Désactiver"/"Réactiver", privacy data that signs the user out).
    public var bulkSelectable = true
    /// Facets the review can filter on ("Source" → "App Store", "Éditeur" → "Adobe"); the key is the filter's label.
    public var tags: [String: String] = [:]
    /// Filters offered at the top of this group's review, in order: the first as chips, the others as menus.
    public var facetKeys: [String] = []
    /// A copy set (duplicates, similar images): its box ticks every copy but the first, the one to keep.
    public var keepsFirst = false

    public init(id: String, title: String, subtitle: String? = nil, symbol: String = "folder",
                groups: [ResultGroup] = [], items: [ResultItem] = [], autoSelect: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.groups = groups
        self.items = items
        self.autoSelect = autoSelect
    }

    public var allItems: [ResultItem] { items + groups.flatMap(\.allItems) }
    /// Items a tick on this group (or on a card holding it) selects: actionable ones, outside non-bulk subgroups.
    public var bulkItems: [ResultItem] {
        guard bulkSelectable else { return [] }
        return (keepsFirst ? Array(items.dropFirst()) : items).filter(\.isActionable) + groups.flatMap(\.bulkItems)
    }
    public var totalSize: Int64 { allItems.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { allItems.isEmpty }

    /// Leaf ids selected by default.
    public var defaultSelection: Set<String> {
        guard autoSelect else { return [] }
        return Set(items.filter(\.autoSelect).map(\.id)).union(groups.flatMap(\.defaultSelection))
    }

    /// Drops empty subgroups recursively.
    public func pruned() -> ResultGroup {
        var g = self
        g.groups = groups.map { $0.pruned() }.filter { !$0.isEmpty }
        return g
    }
}

public enum SelectionState: Sendable { case on, off, mixed }

public extension ResultGroup {
    func selectionState(_ selection: Set<String>) -> SelectionState {
        let ids = allItems.map(\.id)
        let n = ids.filter(selection.contains).count
        return n == 0 ? .off : (n == ids.count ? .on : .mixed)
    }

    func selectedSize(_ selection: Set<String>) -> Int64 {
        allItems.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
}
