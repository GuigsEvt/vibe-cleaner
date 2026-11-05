import AppKit
import Foundation

/// Privacy traces: app permissions granted in the user TCC database, and the
/// Recent Items lists of the Apple menu. Reading both needs Full Disk Access.
enum Privacy {
    static let removeRecentList = "privacy-recent-list"

    // MARK: Permissions (TCC)

    static func tccDatabase(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// French labels of the services; others keep their raw name.
    static let services: [String: String] = [
        "Accessibility": "Accessibilité", "AppleEvents": "Automatisation", "Calendar": "Calendrier",
        "Camera": "Caméra", "AddressBook": "Contacts", "SystemPolicyDesktopFolder": "Dossier Bureau",
        "SystemPolicyDocumentsFolder": "Dossier Documents", "SystemPolicyDownloadsFolder": "Dossier Téléchargements",
        "SystemPolicyAllFiles": "Accès complet au disque", "ListenEvent": "Surveillance de l'entrée",
        "Microphone": "Micro", "SystemPolicyNetworkVolumes": "Volumes réseau", "Photos": "Photos",
        "Reminders": "Rappels", "SystemPolicyRemovableVolumes": "Volumes amovibles",
        "ScreenCapture": "Enregistrement de l'écran", "SpeechRecognition": "Reconnaissance vocale",
        "EndpointSecurityClient": "Sécurité des terminaux",
    ]

    /// System-wide grants (screen recording, accessibility, full disk access…). Readable with Full Disk Access, no root.
    static let systemTCCDatabase = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")

    /// `systemDB` adds the system database when readable; its resets need the administrator prompt.
    static func permissions(context: ModuleContext, systemDB: URL? = nil, appName: (String) -> String? = Privacy.appName) -> ResultGroup {
        let db = tccDatabase(home: context.home)
        let title = "Autorisations des apps", symbol = "hand.raised"
        let system = systemDB.flatMap { SQLite.rows($0, "SELECT service, client, client_type, auth_value FROM access") } ?? []
        guard let rows = SQLite.rows(db, "SELECT service, client, client_type, auth_value FROM access") ?? (system.isEmpty ? nil : []) else {
            return ResultGroup(id: "privacy.tcc", title: title,
                               subtitle: "Base des autorisations illisible : accordez l'accès complet au disque à Vibe Cleaner", symbol: symbol).oneByOne()
        }
        var byService: [String: [ResultItem]] = [:]
        for (row, isSystem) in rows.map({ ($0, false) }) + system.map({ ($0, true) }) {
            // Only bundle-id clients (type 0) can be reset with tccutil; 2 = allowed, 3 = limited.
            guard let raw = row["service"], let client = row["client"], row["client_type"] == "0", isToken(client), isToken(raw),
                  let auth = Int(row["auth_value"] ?? ""), auth >= 2 else { continue }
            let service = raw.hasPrefix("kTCCService") ? String(raw.dropFirst("kTCCService".count)) : raw
            let id = "privacy.tcc.\(service).\(client)\(isSystem ? ".system" : "")"
            guard !(byService[service]?.contains { $0.id == id } ?? false) else { continue }
            var detail = auth == 3 ? "Accès limité — \(client)" : client
            if isSystem { detail += " — réglage système, mot de passe demandé" }
            byService[service, default: []].append(
                ResultItem(id: id, name: appName(client) ?? client, detail: detail, symbol: "app",
                           action: .command(executable: "/usr/bin/tccutil", arguments: ["reset", service, client], admin: isSystem),
                           autoSelect: false))
        }
        let groups = byService.map { service, items in
            ResultGroup(id: "privacy.tcc.\(service)", title: services[service] ?? service, symbol: "lock.open",
                        items: items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, autoSelect: false)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return ResultGroup(id: "privacy.tcc", title: title,
                           subtitle: "Retirer une autorisation : l'app la redemandera si elle en a besoin", symbol: symbol,
                           groups: groups, autoSelect: false).oneByOne()
    }

    /// The "Caméra et micro" tile: the camera and microphone grants of `permissions`, under the same ids, so that
    /// ticking one row ticks both and its reset runs once.
    static func cameraMicrophone(_ permissions: ResultGroup) -> ResultGroup {
        let groups = ["Camera", "Microphone"].compactMap { service -> ResultGroup? in
            guard let g = permissions.groups.first(where: { $0.id == "privacy.tcc.\(service)" }) else { return nil }
            let items = g.items.map { i in
                var item = i
                item.symbol = service == "Camera" ? "camera" : "mic"
                return item
            }
            return ResultGroup(id: "privacy.cammic.\(service)", title: g.title, symbol: service == "Camera" ? "camera" : "mic", items: items, autoSelect: false)
        }
        let apps = Set(groups.flatMap(\.items).map(\.name)).count
        return ResultGroup(id: "privacy.cammic", title: "Caméra et micro",
                           subtitle: apps == 0 ? nil : "\(apps) app(s) ont accès à votre caméra ou à votre micro. Retirez l'accès à celles qui n'en ont pas besoin.",
                           symbol: "video", groups: groups, autoSelect: false).oneByOne()
    }

    /// Bundle ids and service names passed to `tccutil` come from a database: letters, digits, dots, dashes and
    /// underscores only (no option, no path, no space).
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.count <= 255
            && s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) }
    }

    static func appName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: Recent Items

    static func sharedFileLists(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
    }

    static func recentItems(context: ModuleContext) -> ResultGroup {
        let root = sharedFileLists(home: context.home)
        let fm = FileManager.default
        let lists: [(String, String, String)] = [
            ("com.apple.LSSharedFileList.RecentApplications", "Applications récentes", "app"),
            ("com.apple.LSSharedFileList.RecentDocuments", "Documents récents", "doc"),
            ("com.apple.LSSharedFileList.RecentServers", "Serveurs récents", "server.rack"),
        ]
        var items: [ResultItem] = []
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for (prefix, name, symbol) in lists {
            for file in top where file.lastPathComponent.hasPrefix(prefix + ".sfl") {
                if let item = listItem(file, name: name, symbol: symbol, context: context) { items.append(item) }
            }
        }
        let perApp = root.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
        for file in (try? fm.contentsOfDirectory(at: perApp, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension.hasPrefix("sfl") {
            let bundleID = file.deletingPathExtension().lastPathComponent
            if let item = listItem(file, name: "Documents récents de \(appName(bundleID) ?? bundleID)", symbol: "doc.on.doc", context: context) {
                items.append(item)
            }
        }
        return ResultGroup(id: "privacy.recent", title: "Éléments récents",
                           subtitle: "Apps, documents et serveurs listés dans le menu Pomme > Éléments récents", symbol: "clock",
                           items: items, autoSelect: false).oneByOne()
    }

    static func listItem(_ file: URL, name: String, symbol: String, context: ModuleContext) -> ResultItem? {
        guard !context.isExcluded(file) else { return nil }
        let names = entryNames(file)
        guard names.map({ !$0.isEmpty }) ?? true else { return nil }
        let detail = names.map { n in "\(n.count) élément(s) : \(n.prefix(4).joined(separator: ", "))\(n.count > 4 ? "…" : "")" }
        return ResultItem(id: "privacy.recent.\(file.path)", name: name, detail: detail ?? file.lastPathComponent, url: file,
                          size: FileSizer.size(of: file), symbol: symbol, action: .custom(removeRecentList), autoSelect: false)
    }

    /// Names of the entries of a `.sfl2`/`.sfl3` list (a keyed archive with an `items` array), or nil if unreadable.
    static func entryNames(_ file: URL) -> [String]? {
        guard let data = try? Data(contentsOf: file),
              let root = try? NSKeyedUnarchiver.unarchivedObject(
                ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSData.self, NSNumber.self, NSUUID.self, NSDate.self, NSURL.self],
                from: data) as? [String: Any],
              let entries = root["items"] as? [[String: Any]] else { return nil }
        return entries.map { entry in
            if let name = entry["Name"] as? String { return name }
            if let bookmark = entry["Bookmark"] as? Data,
               let name = URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: bookmark)?.name { return name }
            return "?"
        }
    }
}
