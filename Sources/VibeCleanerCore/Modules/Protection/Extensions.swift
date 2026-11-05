import Foundation

/// Browser extensions and the Safari homepage. Everything is read only;
/// Chrome extensions can be quarantined with the browser closed, Safari ones are removed from Safari.
enum Extensions {
    static let chromeKeyPrefix = "ext:"
    static let storeUpdateURLs: Set<String> = ["https://clients2.google.com/service/update2/crx",
                                               "https://edge.microsoft.com/extensionwebstorebase/v1/crx"]
    static let broadHosts: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"]
    static let sensitiveAPIs: Set<String> = ["proxy", "debugger", "management", "nativeMessaging"]

    // MARK: Safari

    /// Parses `pluginkit -m -v` lines: `+    com.x.Ext(1.0)<TAB>UUID<TAB>date<TAB>/path/Ext.appex`.
    static func parsePluginKit(_ output: String) -> [(id: String, path: String, enabled: Bool)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, let path = fields.last.map(String.init), path.hasPrefix("/") else { return nil }
            let head = fields[0]
            let enabled = head.first == "+"
            var id = head.drop { "+-!=? ".contains($0) }
            if let paren = id.lastIndex(of: "(") { id = id[..<paren] }
            return (String(id), path, enabled)
        }
    }

    /// The app that embeds an extension (`/Applications/Foo.app/Contents/PlugIns/X.appex` → `/Applications/Foo.app`).
    static func containingApp(_ path: String) -> URL {
        if let r = path.range(of: ".app/", options: .backwards) { return URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app") }
        return URL(fileURLWithPath: path)
    }

    static func safari(pluginKit output: String, context: ModuleContext, excludedTeamIDs: Set<String>,
                       check: (URL) -> SignatureInfo = { CodeSignature.check($0, validateResources: false) }) -> [ResultItem] {
        parsePluginKit(output).compactMap { ext in
            let app = containingApp(ext.path)
            guard !context.isExcluded(app) else { return nil }
            let sig = check(app)
            if let t = sig.teamID, excludedTeamIDs.contains(t) { return nil }
            let reason: String
            if sig.status == .invalid { reason = "Application à la signature invalide" }
            else if sig.status == .unsigned { reason = "Application non signée" }
            else if ProtectionModule.isSuspiciousLocation(app, home: context.home) { reason = "Installée dans un emplacement suspect" }
            else { return nil }
            return ResultItem(id: "prot.ext.safari.\(ext.id)", name: ext.id,
                              detail: "\(ThreatType.suspicious.label) · \(reason)\(ext.enabled ? "" : " (désactivée)") — à retirer dans Safari > Réglages > Extensions, ou en supprimant \(app.lastPathComponent)",
                              url: app, symbol: "safari", action: .none, autoSelect: false)
        }
    }

    // MARK: Chrome and Chromium

    /// Sensitive APIs in plain French, for the reason shown to the user.
    static let sensitiveNames = ["proxy": "contrôle du proxy réseau", "debugger": "débogueur", "management": "gestion des autres extensions",
                                 "nativeMessaging": "échange avec une app du Mac"]

    /// Widely used Web Store extensions whose broad rights are their job (password managers, writing, assistants).
    /// Matched by store id, so a lookalike under another id, or the same id installed outside the store, is still listed.
    static let knownStoreIDs: Set<String> = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa", // 1Password
        "nngceckbapebfimnlniiiahkandclblb", // Bitwarden
        "hdokiejnpimakedhajhdlcegeplioahd", // LastPass
        "kbfnbcaeplbcioakkpcpgfkobkghlhen", // Grammarly
        "fcoeoabgfenejglbfodgkkbkcdhcgfn", // Claude
    ]

    /// Why an extension deserves a look, or nil. Outside the Web Store it is "Suspect"; from the store with broad
    /// rights it only has "Droits étendus", which many legitimate extensions need.
    static func chromeVerdict(_ manifest: [String: Any], id: String = "") -> (label: String, reason: String)? {
        let update = manifest["update_url"] as? String
        let offStore = update.map { !storeUpdateURLs.contains($0) } ?? true
        let perms = (manifest["permissions"] as? [Any] ?? []) + (manifest["host_permissions"] as? [Any] ?? [])
        let names = Set(perms.compactMap { $0 as? String })
        let scripts = (manifest["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] }
        let broad = !names.isDisjoint(with: broadHosts) || scripts.contains(where: broadHosts.contains)
        let sensitive = names.intersection(sensitiveAPIs).sorted().map { sensitiveNames[$0] ?? $0 }
        let suspect = ThreatType.suspicious.label
        if offStore && broad { return (suspect, "Installée hors Web Store, accès à tous les sites") }
        if offStore { return (suspect, "Installée hors Web Store") }
        if knownStoreIDs.contains(id) { return nil }
        if broad && !sensitive.isEmpty {
            return ("Droits étendus", "Accès à tous les sites et droits sensibles : \(sensitive.joined(separator: ", "))")
        }
        return nil
    }

    static func chromeReason(_ manifest: [String: Any]) -> String? { chromeVerdict(manifest)?.reason }

    /// A browser or extension file read in full, refused past `limit`: a hostile manifest cannot fill memory.
    static func smallFile(_ url: URL, limit: Int = 4_000_000) -> Data? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Profile folder → name chosen in the browser ("Profile 16" → "Travail"), from `Local State`.
    static func profileNames(_ root: URL) -> [String: String] {
        guard let data = smallFile(root.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
    }

    /// `__MSG_key__` names are looked up in the default locale.
    static func displayName(_ manifest: [String: Any], dir: URL) -> String? {
        guard let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = name.dropFirst(6).dropLast(2).lowercased()
        // A locale is a language code, never a path: "../../x" would read a file outside the extension.
        let locale = manifest["default_locale"] as? String ?? "en"
        guard locale.range(of: #"^[A-Za-z]{2,3}(_[A-Za-z0-9]{2,4})?$"#, options: .regularExpression) != nil else { return nil }
        let file = dir.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let data = smallFile(file), let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any] else { return nil }
        return entry["message"] as? String
    }

    static func chrome(context: ModuleContext) -> [ResultItem] {
        let fm = FileManager.default
        var items: [ResultItem] = []
        for b in Browsers.chromium {
            let root = context.home.appendingPathComponent("Library/Application Support").appendingPathComponent(b.folder)
            let profiles = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let profileNames = profileNames(root)
            for profile in profiles {
                let folder = profile.lastPathComponent
                let location = profileNames[folder].map { "\(b.name), profil « \($0) » (\(folder))" } ?? "\(b.name) (\(folder))"
                let exts = (try? fm.contentsOfDirectory(at: profile.appendingPathComponent("Extensions"), includingPropertiesForKeys: nil)) ?? []
                for ext in exts where !context.isExcluded(ext) {
                    let versions = ((try? fm.contentsOfDirectory(at: ext, includingPropertiesForKeys: nil)) ?? [])
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                    guard let dir = versions.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }),
                          let data = smallFile(dir.appendingPathComponent("manifest.json")),
                          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let verdict = chromeVerdict(manifest, id: ext.lastPathComponent) else { continue }
                    let name = displayName(manifest, dir: dir) ?? ext.lastPathComponent
                    // Reason first: a long line is cut in the middle, the why must stay readable.
                    items.append(ResultItem(id: "prot.ext.chrome.\(ext.path)", name: name,
                                            detail: "\(verdict.label) · \(verdict.reason) — \(location) — \(ext.lastPathComponent)",
                                            url: ext, size: FileSizer.size(of: ext), symbol: "puzzlepiece.extension",
                                            action: .custom(chromeKeyPrefix + b.bundleID), autoSelect: false))
                }
            }
        }
        return items
    }

    static func group(safari: [ResultItem], chrome: [ResultItem]) -> ResultGroup {
        var groups: [ResultGroup] = []
        if !safari.isEmpty { groups.append(ResultGroup(id: "prot.ext.safari", title: "Safari", symbol: "safari", items: safari)) }
        if !chrome.isEmpty { groups.append(ResultGroup(id: "prot.ext.chrome", title: "Chrome et Chromium", symbol: "puzzlepiece.extension", items: chrome)) }
        return ResultGroup(id: "prot.extensions", title: "Extensions de navigateur à vérifier",
                           subtitle: "Extensions installées hors des boutiques officielles ou aux droits étendus. Le navigateur doit être fermé pour les retirer.",
                           symbol: "puzzlepiece.extension", groups: groups, autoSelect: false)
    }

    // MARK: Safari homepage

    static let trustedHomeHosts = ["google.", "bing.com", "duckduckgo.com", "ecosia.org", "qwant.com", "yahoo.", "startpage.com",
                                   "apple.com", "kagi.com", "search.brave.com", "yandex.", "baidu.com"]

    static func homepageReason(_ homepage: String, managed: Bool) -> String? {
        if managed { return "Imposée par un profil de configuration" }
        guard let host = URL(string: homepage)?.host?.lowercased() else { return nil }
        if trustedHomeHosts.contains(where: { Self.isHost(host, of: $0) }) { return nil }
        return host.contains("search") || host.contains("find") ? "Moteur de recherche inconnu (\(host))" : nil
    }

    /// `host` is the domain or one of its subdomains. A trailing dot ("google.") stands for any country TLD of one or
    /// two labels ("google.fr", "google.co.uk"), never a longer name: "google.evil-search.ru" is not Google.
    static func isHost(_ host: String, of domain: String) -> Bool {
        let labels = host.split(separator: ".").map(String.init)
        if domain.hasSuffix(".") {
            let name = String(domain.dropLast())
            guard let i = labels.lastIndex(of: name) else { return false }
            let tld = labels.count - i - 1
            return tld == 1 || (tld == 2 && labels[labels.count - 2].count <= 3)
        }
        return host == domain || host.hasSuffix("." + domain)
    }

    static func homepage(_ plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (dict["HomePage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Reads Safari's preferences without writing them; managed preferences (forced by a profile) win.
    static func safariHomepage(context: ModuleContext, managedRoot: URL = URL(fileURLWithPath: "/Library/Managed Preferences"),
                               user: String = NSUserName(), fullDiskAccess: Bool = true) -> ResultGroup {
        let managed = [managedRoot.appendingPathComponent("\(user)/com.apple.Safari.plist"), managedRoot.appendingPathComponent("com.apple.Safari.plist")]
        var prefs = [context.home.appendingPathComponent("Library/Preferences/com.apple.Safari.plist")]
        if fullDiskAccess { prefs.insert(context.home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"), at: 0) }
        var items: [ResultItem] = []
        if let (page, isManaged) = managed.lazy.compactMap({ homepage($0).map { ($0, true) } }).first
            ?? prefs.lazy.compactMap({ homepage($0).map { ($0, false) } }).first,
           let reason = homepageReason(page, managed: isManaged) {
            items.append(ResultItem(id: "prot.homepage.\(page)", name: page,
                                    detail: "\(ThreatType.adware.label) · \(reason) — à changer dans Safari > Réglages > Général\(isManaged ? " après avoir retiré le profil" : "")",
                                    symbol: "house", action: .none, autoSelect: false))
        }
        return ResultGroup(id: "prot.homepage", title: "Page d'accueil Safari détournée", symbol: "house", items: items, autoSelect: false)
    }
}
