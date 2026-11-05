import Foundation

/// Stand-alone plug-ins installed in ~/Library and /Library (audio, Quick Look, screen savers, preference panes…),
/// and system extensions as listed by `systemextensionsctl list`.
enum Plugins {
    struct Kind: Sendable {
        let id: String
        let title: String
        let symbol: String
        /// Folders relative to a Library folder.
        let dirs: [String]
    }

    static let kinds: [Kind] = [
        Kind(id: "audio", title: "Plug-ins audio", symbol: "waveform",
             dirs: ["Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Audio/Plug-Ins/CLAP",
                    "Application Support/Avid/Audio/Plug-Ins"]),
        Kind(id: "quicklook", title: "Extensions Quick Look", symbol: "eye", dirs: ["QuickLook"]),
        Kind(id: "savers", title: "Économiseurs d'écran", symbol: "tv", dirs: ["Screen Savers"]),
        Kind(id: "prefpanes", title: "Panneaux de préférences", symbol: "gearshape", dirs: ["PreferencePanes"]),
        Kind(id: "internet", title: "Plug-ins Internet", symbol: "globe", dirs: ["Internet Plug-Ins"]),
        Kind(id: "spotlight", title: "Importateurs Spotlight", symbol: "magnifyingglass", dirs: ["Spotlight"]),
    ]

    struct Plugin: Sendable, Equatable {
        let url: URL
        let kind: String
        let bundleID: String?
    }

    /// Bundles directly in each plug-in folder, and one level of vendor subfolders. Apple's own are skipped.
    static func find(libraries: [URL]) -> [Plugin] {
        var out: [Plugin] = []
        for lib in libraries {
            for kind in kinds {
                for dir in kind.dirs {
                    for entry in AppInventory.children(of: lib.appendingPathComponent(dir)) where !entry.lastPathComponent.hasPrefix(".") {
                        let bundles = entry.pathExtension.isEmpty && AppInventory.isPlainDirectory(entry)
                            ? AppInventory.children(of: entry).filter { !$0.pathExtension.isEmpty } : [entry]
                        for b in bundles {
                            let id = AppInventory.readPlist(b.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
                            if id?.lowercased().hasPrefix("com.apple.") == true { continue }
                            out.append(Plugin(url: b, kind: kind.id, bundleID: id))
                        }
                    }
                }
            }
        }
        return out
    }

    struct SystemExtension: Sendable, Equatable {
        let teamID: String
        let bundleID: String
        let version: String
        let name: String
        let state: String
    }

    /// Rows of `systemextensionsctl list`: "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]".
    static func parseSystemExtensions(_ output: String) -> [SystemExtension] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // The header row ("enabled\tactive…") has words where data rows have "*" or nothing.
            guard cols.count >= 6, cols[0].isEmpty || cols[0] == "*", let open = cols[3].firstIndex(of: "("), cols[3].hasSuffix(")") else { return nil }
            let id = cols[3][..<open].trimmingCharacters(in: .whitespaces)
            let version = String(cols[3][cols[3].index(after: open)..<cols[3].index(before: cols[3].endIndex)])
            guard !id.isEmpty, !id.hasPrefix("com.apple.") else { return nil }
            return SystemExtension(teamID: cols[2], bundleID: id, version: version, name: cols[4],
                                   state: cols[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        }
    }

    static func listSystemExtensions() -> String { Shell.run("/usr/bin/systemextensionsctl", ["list"]).stdout }
}
