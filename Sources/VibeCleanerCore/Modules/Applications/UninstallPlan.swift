import Foundation

/// What uninstalling one app removes, as the app's "Toutes les applications" group lists it (bundle first).
/// Used by the Shortcuts action so it confirms and executes exactly what the module would.
public struct UninstallPlan: Sendable {
    public let app: InstalledApp
    public let items: [ResultItem]

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var needsAdmin: Bool {
        items.contains {
            switch $0.action {
            case .delete(_, _, let admin), .command(_, _, let admin): admin
            case .custom, .none: false
            }
        }
    }

    /// Confirmation text: the app, the total and each item that goes, capped at `limit` lines.
    /// `running`: the app is open and will be asked to quit first, which the user must know before confirming.
    public func summary(limit: Int = 12, running: Bool = false) -> String {
        var lines = ["« \(app.name) » et \(items.count - 1) fichier(s) associé(s) iront à la Corbeille (\(FileSizer.format(totalSize))) :"]
        lines += items.prefix(limit).map { "• " + ($0.url?.path ?? [$0.name, $0.detail].compactMap { $0 }.joined(separator: " — ")) }
        if items.count > limit { lines.append("• … et \(items.count - limit) autre(s)") }
        if running { lines.append("« \(app.name) » est ouverte : elle sera d'abord quittée (les documents non enregistrés vous seront demandés).") }
        if needsAdmin { lines.append("Le mot de passe administrateur sera demandé.") }
        return lines.joined(separator: "\n")
    }
}

public extension ApplicationsModule {
    /// Installed apps that can be uninstalled (not system, Apple, proxy or Vibe Cleaner itself), sorted by name.
    func removableApps(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [InstalledApp] {
        installedApps(home: home).filter { !$0.isProtected }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Nil when the bundle is not an installed, removable app or is excluded by the user. Read only.
    func uninstallPlan(for url: URL, context: ModuleContext) -> UninstallPlan? {
        let installed = installedApps(home: context.home)
        let path = url.standardizedFileURL.path
        guard var app = installed.first(where: { $0.url.standardizedFileURL.path == path }), !app.isProtected,
              !context.isExcluded(app.url) else { return nil }
        app.size = FileSizer.size(of: app.url)
        let finder = footprintFinder(home: context.home, installed: installed)
        return UninstallPlan(app: app, items: [bundleItem(app, home: context.home)] + fileItems(app, finder.footprint(of: app), context: context)
            + extraItems(app, finder: finder))
    }
}
