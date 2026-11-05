import Foundation

/// Volume bar: used, selected, purgeable and free segments, summing to the capacity.
public struct VolumeGauge: Equatable, Sendable {
    public let total: Int64
    /// Used space not counting the selection nor purgeable space.
    public let used: Int64
    public let selected: Int64
    public let purgeable: Int64
    public let free: Int64

    /// Clamped: purgeable never exceeds what is not free, the selection never exceeds used space.
    public init(volume: VolumeInfo, selected: Int64) {
        total = max(0, volume.totalCapacity)
        free = min(max(0, volume.availableCapacity), total)
        purgeable = min(max(0, volume.purgeableCapacity), total - free)
        let usedAll = total - free - purgeable
        self.selected = min(max(0, selected), usedAll)
        used = usedAll - self.selected
    }
}

public let purgeableExplanation = """
L'espace purgeable regroupe ce que macOS juge sûr d'effacer quand le disque se remplit : instantanés locaux \
Time Machine, caches, contenus téléchargeables à nouveau. macOS le libère tout seul quand il en a besoin. \
Vibe Cleaner ne le vide pas : macOS n'offre aucune API publique pour forcer cette libération.
"""

public let smallerItemsExplanation = "Fichiers et dossiers divers qui occupent de l'espace"

public extension SpaceNode {
    /// Selected bytes inside self; `entire` when self or one of its ancestors is selected.
    func selection(in selected: Set<String>) -> (bytes: Int64, entire: Bool) {
        if ancestry.contains(where: { selected.contains($0.path) }) { return (size, true) }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let bytes = SpaceNode.outermost(selected).filter { $0.hasPrefix(prefix) }.compactMap { node(at: $0)?.size }.reduce(0, +)
        return (bytes, false)
    }

    /// Bubble and list tooltip: size, modification date, selection, system folder.
    func tooltip(selected: Set<String>) -> String {
        var lines = [name.isEmpty ? "/" : name, "Taille : \(FileSizer.format(size))"]
        if let d = modificationDate { lines.append("Modifié : \(d.formatted(date: .abbreviated, time: .shortened))") }
        let s = selection(in: selected)
        if s.entire { lines.append(isDirectory && !isPackage ? "Sélectionné : dossier entier" : "Sélectionné") }
        else if s.bytes > 0 { lines.append("Sélectionné : \(FileSizer.format(s.bytes))") }
        if isProtected { lines.append("Dossier système") }
        return lines.joined(separator: "\n")
    }
}

public extension SpaceNode {
    /// Applies a removal to the tree (ancestor sizes updated, no rescan) and builds its journal entry:
    /// one `CleanupLog` per grouped removal, module "radar". The freed size is the nodes' known size
    /// (hard-linked files count 0), the remover's measure only for a path missing from the tree.
    @discardableResult
    func apply(_ removal: RemovalReport, dryRun: Bool, date: Date = Date()) -> CleanupLog {
        var report = ExecutionReport()
        var unknown = false
        for url in removal.removed {
            let path = url.standardizedFileURL.path
            report.processed.append(path)
            report.log.append("Corbeille : \(path)")
            guard let n = node(at: path) else { unknown = true; continue }
            report.freedBytes += n.size
            if !dryRun { n.detach() }
        }
        if unknown { report.freedBytes = removal.freedBytes }
        report.failures = removal.failures.map { (id: $0.0.path, reason: $0.1) }
        return CleanupLog(report: report, module: "radar", dryRun: dryRun, date: date)
    }
}
