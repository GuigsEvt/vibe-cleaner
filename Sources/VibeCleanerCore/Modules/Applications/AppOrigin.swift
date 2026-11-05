import Foundation

/// Vendor and store of an installed app, for the "Par éditeur" / "Par source" filters.
enum AppOrigin {
    static let vendors: [(name: String, prefixes: [String])] = [
        ("Apple", ["com.apple", "developer.apple."]),
        ("Adobe", ["com.adobe", "adobe."]),
        ("Google", ["com.google."]),
        ("JetBrains", ["com.jetbrains", "org.jetbrains", "com.kotlinconf.iosapp"]),
        ("Microsoft", ["com.microsoft.", "com.skype.", "com.followanalytics.adventureworks.msdc365"]),
    ]
    static let otherVendor = "Autres éditeurs"

    static func vendor(_ app: InstalledApp) -> String {
        let id = app.bundleID?.lowercased() ?? ""
        return vendors.first { $0.prefixes.contains { id.hasPrefix($0) } }?.name ?? otherVendor
    }

    enum Store: String, CaseIterable {
        case appStore = "App Store", setapp = "Setapp", steam = "Steam", battleNet = "Battle.net"
        case toolbox = "JetBrains Toolbox", other = "Internet et autres"

        var subtitle: String {
            switch self {
            case .appStore: "Apps installées depuis l'App Store."
            case .setapp: "Apps installées avec Setapp. Setapp peut aussi les désinstaller."
            case .steam: "Jeux lancés par Steam. Steam peut aussi les désinstaller."
            case .battleNet: "Jeux et lanceur Blizzard installés avec Battle.net."
            case .toolbox: "IDE installés et mis à jour par JetBrains Toolbox."
            case .other: "Apps installées depuis le site de leur éditeur ou un autre moyen."
            }
        }
    }

    static func store(_ app: InstalledApp, home: URL) -> Store {
        let id = app.bundleID?.lowercased() ?? ""
        let path = app.url.standardizedFileURL.path
        if app.source == .appStore { return .appStore }
        if id.hasSuffix("-setapp") || path.contains("/Setapp/") { return .setapp }
        if id.hasPrefix("com.blizzard.") || id.hasPrefix("net.battle.") { return .battleNet }
        if path.contains("/steamapps/") || isSteamLauncher(app.url) { return .steam }
        let toolbox = home.appendingPathComponent("Library/Application Support/JetBrains/Toolbox")
        if path.contains("/JetBrains/Toolbox/") || (id.hasPrefix("com.jetbrains.") && path.hasPrefix(home.path + "/Applications/")
                                                     && FileManager.default.fileExists(atPath: toolbox.path)) { return .toolbox }
        return .other
    }

    /// Steam's desktop shortcuts are tiny apps whose `run.sh` opens `steam://run/<id>`.
    static func isSteamLauncher(_ app: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: app.appendingPathComponent("Contents/MacOS/run.sh")) else { return false }
        defer { try? fh.close() }
        let head = String(decoding: (try? fh.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return head.contains("steam://run/")
    }
}

/// Games installed by Steam: one folder under `steamapps/common` and one `appmanifest_<id>.acf` per game, in each library.
enum SteamLibrary {
    struct Game: Sendable, Equatable {
        let id: String
        let name: String
        let folder: URL
        let manifest: URL
    }

    static func games(home: URL) -> [Game] {
        let main = home.appendingPathComponent("Library/Application Support/Steam")
        let vdf = (try? String(contentsOf: main.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8)) ?? ""
        var libraries = [main.standardizedFileURL.path]
        for p in values("path", in: vdf) where !libraries.contains(p) { libraries.append(p) }
        var out: [Game] = []
        for lib in libraries {
            let apps = URL(fileURLWithPath: lib).appendingPathComponent("steamapps")
            for manifest in AppInventory.children(of: apps) where manifest.lastPathComponent.hasPrefix("appmanifest_")
                && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let id = values("appid", in: text).first, let dir = values("installdir", in: text).first,
                      !dir.isEmpty, !dir.contains("/"), dir != "..", dir != "." else { continue }
                let folder = apps.appendingPathComponent("common").appendingPathComponent(dir)
                guard AppInventory.isPlainDirectory(folder) else { continue }
                out.append(Game(id: id, name: values("name", in: text).first ?? dir, folder: folder, manifest: manifest))
            }
        }
        return out
    }

    /// Every `"key"  "value"` pair of a Valve KeyValues (VDF/ACF) text, case-insensitive on the key.
    static func values(_ key: String, in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            // `"key" "value"` splits into ["\t", key, "\t\t", value, ""].
            guard parts.count >= 5, parts[1].caseInsensitiveCompare(key) == .orderedSame,
                  parts[2].allSatisfy(\.isWhitespace) else { continue }
            out.append(parts[3].replacingOccurrences(of: "\\\\", with: "\\"))
        }
        return out
    }
}
