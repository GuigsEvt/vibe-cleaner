import Foundation

/// Logs. Not regenerable data: user logs go to the Trash; root logs go through the admin batch.
enum LogScanner {
    static func userLogs(_ s: JunkScope) -> ResultGroup {
        var g = ResultGroup(id: "cleanup.system.userLogs", title: "Journaux utilisateur",
                            subtitle: "Journaux et rapports de plantage de vos apps", symbol: "doc.text")
        for url in Junk.children(s.lib("Logs")) where !DefaultIgnores.isOwn(url.lastPathComponent) {
            if Task.isCancelled { break }
            append(url, into: &g, s)
        }
        for container in Junk.children(s.lib("Containers")) {
            if Task.isCancelled { break }
            let logs = container.appendingPathComponent("Data/Library/Logs")
            guard !Junk.isSymlink(logs) else { continue }
            let items = Junk.children(logs).compactMap { s.item($0, mode: .trash) }
            if !items.isEmpty {
                g.groups.append(ResultGroup(id: "\(g.id).\(container.lastPathComponent)", title: "\(container.lastPathComponent) (conteneur)", items: items))
            }
        }
        for name in ["com.apple.LaunchServices.QuarantineEventsV2", "com.apple.LaunchServices.QuarantineEvents"] {
            // V2 is the SQLite database lsd keeps open: never selected by default.
            if let item = s.item(s.lib("Preferences/\(name)"), name: "Historique des téléchargements (\(name))", mode: .trash,
                                 auto: !name.hasSuffix("V2")) { g.items.append(item) }
        }
        return g
    }

    /// A log file is an item; a log folder becomes a subgroup of its entries.
    static func append(_ url: URL, into g: inout ResultGroup, _ s: JunkScope, auto: Bool = true) {
        if Junk.isDirectory(url) {
            let items = Junk.children(url).compactMap { s.item($0, mode: .trash, auto: auto) }
            if !items.isEmpty { g.groups.append(ResultGroup(id: url.path, title: url.lastPathComponent, items: items)) }
        } else if let item = s.item(url, mode: .trash, auto: auto) {
            g.items.append(item)
        }
    }

    static let rotatedNames: Set<String> = ["daily.out", "weekly.out", "monthly.out"]

    /// Only rotated or archived files in /private/var/log; never /private/var/db/diagnostics.
    static func isRotatedLog(_ name: String) -> Bool {
        rotatedNames.contains(name) || name.hasSuffix(".gz") || name.hasSuffix(".bz2")
    }

    static func systemLogs(_ s: JunkScope) -> ResultGroup? {
        guard s.system else { return nil }
        var g = ResultGroup(id: "cleanup.system.systemLogs", title: "Journaux système",
                            subtitle: "Journaux de /Library/Logs et journaux archivés de /private/var/log (droits administrateur)", symbol: "doc.text.below.ecg")
        for url in Junk.children(URL(fileURLWithPath: "/Library/Logs")) { append(url, into: &g, s, auto: false) }
        for url in Junk.children(URL(fileURLWithPath: "/private/var/log")) where isRotatedLog(url.lastPathComponent) {
            if let item = s.item(url, mode: .permanent, auto: false) { g.items.append(item) }
        }
        for url in Junk.children(URL(fileURLWithPath: "/private/var/log/asl")) where url.pathExtension == "asl" {
            if let item = s.item(url, mode: .permanent, auto: false) { g.items.append(item) }
        }
        return g
    }
}
