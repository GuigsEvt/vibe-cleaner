import Foundation

/// "Vider la corbeille" of the menu, the notification and the Shortcuts action: the user's `~/.Trash`
/// emptied item by item through `SafeRemover` (exclusions, simulation), never by driving the Finder.
/// Permanent by nature: these items are already in the Trash. Volume `.Trashes` are left alone,
/// so what is removed matches the size shown in the menu.
public enum TrashBin {
    public static func url(home: URL) -> URL { home.appendingPathComponent(".Trash", isDirectory: true) }

    /// One permanent deletion per top-level entry; nil when the Trash cannot be listed (Full Disk Access missing).
    public static func items(home: URL) -> [ResultItem]? {
        let trash = url(home: home)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return nil }
        return entries.sorted { $0.path < $1.path }.map { ResultItem.file($0, mode: .permanent) }
    }

    public static let unreadable = "La corbeille n'a pas pu être lue : accordez l'accès complet au disque à Vibe Cleaner."

    /// Empties `remover.home/.Trash` through `ActionExecutor` (so `SafeRemover`); in simulation nothing moves.
    public static func emptyUserTrash(remover: SafeRemover) throws -> ExecutionReport {
        let home = URL(fileURLWithPath: remover.home, isDirectory: true)
        guard let items = items(home: home) else { throw RemovalError.failed(url(home: home).path, unreadable) }
        return ActionExecutor(remover: remover).run(items)
    }

    /// One line for the menu, the notification and the Shortcuts dialog.
    public static func message(_ report: ExecutionReport, dryRun: Bool) -> String {
        let freed = FileSizer.format(report.freedBytes)
        if dryRun {
            return report.processed.isEmpty ? "Mode simulation : la corbeille est vide, rien n'a été modifié."
                : "Mode simulation : \(report.processed.count) élément(s), \(freed), auraient été supprimés. Rien n'a été modifié."
        }
        let why = report.failures.first?.reason ?? ""
        switch report.outcome {
        case .empty: return "La corbeille est déjà vide."
        case .success: return "Corbeille vidée : \(freed) libérés."
        case .partial: return "Corbeille vidée en partie (\(freed) libérés) : \(report.failures.count) élément(s) n'ont pas pu être supprimés. \(why)"
        case .failure: return "La corbeille n'a pas pu être vidée. \(why)"
        }
    }
}

/// "Libérer la RAM" outside Performance: the same `purge` item, run as root by `ActionExecutor` (one admin prompt,
/// skipped in simulation). A real success is recorded in `MaintenanceHistory`, so Performance does not tick it again.
public enum MemoryPurge {
    public static let item = ResultItem(id: "performance.task.freeRAM", name: "Libérer de la RAM",
                                        action: .command(executable: "/usr/sbin/purge", arguments: [], admin: true))

    public static func run(remover: SafeRemover, history: MaintenanceHistory = .init()) -> ExecutionReport {
        let report = ActionExecutor(remover: remover, adminPrompt: "Vibe Cleaner veut libérer la mémoire inactive.").run([item])
        if !remover.dryRun, report.outcome == .success { history.record(["freeRAM"]) }
        return report
    }

    public static func message(_ report: ExecutionReport, dryRun: Bool) -> String {
        if dryRun { return "Mode simulation : la mémoire n'a pas été libérée." }
        return report.outcome == .success ? "Mémoire inactive libérée." : "La mémoire n'a pas été libérée (opération annulée ou refusée)."
    }
}
