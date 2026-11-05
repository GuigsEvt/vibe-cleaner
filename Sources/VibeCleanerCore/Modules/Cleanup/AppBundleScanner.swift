import Foundation

/// Unused localizations. Universal binaries are not listed: thinning them (`lipo`) breaks the signature,
/// so the card only showed what could never be cleaned.
enum AppBundleScanner {

    // MARK: Languages

    /// Base language code of an `.lproj` name ("French" → "fr", "pt_BR" → "pt"), with the `ua`/`jp` fixes.
    static func languageCode(_ lproj: String) -> String {
        let canonical = Locale.canonicalLanguageIdentifier(from: lproj)
        let first: Substring = canonical.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(lproj)
        let code = first.lowercased()
        return ["ua": "uk", "jp": "ja"][code] ?? code
    }

    static var keptLanguages: Set<String> {
        var keep: Set<String> = ["base", "en"]
        for id in Locale.preferredLanguages { keep.insert(languageCode(id)) }
        if let c = Locale.current.language.languageCode?.identifier { keep.insert(c.lowercased()) }
        return keep
    }

    /// Paths sealed by the app's code signature (keys of `files`/`files2`, relative to Contents/).
    static func sealedPaths(_ app: URL) -> [String] {
        guard let res = Junk.plist(app.appendingPathComponent("Contents/_CodeSignature/CodeResources")) else { return [] }
        return ["files", "files2"].flatMap { (res[$0] as? [String: Any])?.keys.map { $0 } ?? [] }
    }

    static func onlyStrings(_ lproj: URL) -> Bool {
        guard let e = Junk.fm.enumerator(at: lproj, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        var any = false
        for case let f as URL in e {
            if Junk.isDirectory(f) { return false }
            guard ["strings", "stringsdict"].contains(f.pathExtension) || f.lastPathComponent == ".DS_Store" else { return false }
            any = true
        }
        return any
    }

    static func languages(_ s: JunkScope) -> ResultGroup {
        let keep = keptLanguages
        var byLanguage: [String: [ResultItem]] = [:]
        for app in Junk.applications(s) {
            if Task.isCancelled { break }
            let info = Junk.plist(app.appendingPathComponent("Contents/Info.plist")) ?? [:]
            guard !((info["CFBundleIdentifier"] as? String)?.hasPrefix("com.apple.") ?? false) else { continue }
            let sealed = sealedPaths(app)
            let appName = app.deletingPathExtension().lastPathComponent
            for lproj in Junk.children(app.appendingPathComponent("Contents/Resources")) where lproj.pathExtension == "lproj" {
                let name = lproj.lastPathComponent
                let code = languageCode(lproj.deletingPathExtension().lastPathComponent)
                guard !keep.contains(code), !sealed.contains(where: { $0.hasPrefix("Resources/\(name)/") }), onlyStrings(lproj),
                      let item = s.item(lproj, name: "\(appName) — \(name)", detail: app.path, mode: .trash, auto: false) else { continue }
                byLanguage[code, default: []].append(item)
            }
        }
        let fr = Locale(identifier: "fr_FR")
        let groups = byLanguage.map { code, items in
            ResultGroup(id: "cleanup.system.languages.\(code)", title: fr.localizedString(forLanguageCode: code)?.capitalized ?? code,
                        subtitle: code, symbol: "character.bubble", items: items, autoSelect: false)
        }.sorted { $0.title < $1.title }
        return ResultGroup(id: "cleanup.system.languages", title: "Fichiers de langue",
                           subtitle: "Traductions inutilisées des apps non signées (les apps signées ne peuvent pas être modifiées)",
                           symbol: "globe", groups: groups, autoSelect: false)
    }
}
