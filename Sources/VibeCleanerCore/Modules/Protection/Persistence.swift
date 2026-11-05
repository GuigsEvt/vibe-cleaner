import Foundation

/// The user's crontab (`crontab -l`, no root): lines that download and run code, drive AppleScript,
/// decode hidden payloads or run something from a hidden or temporary folder.
enum Cron {
    static let removeKey = "cron-remove"
    static let idPrefix = "prot.cron."

    static func suspiciousReason(_ line: String) -> String? {
        let l = line.lowercased()
        if l.range(of: #"(curl|wget)[^|;]*\|\s*(sudo\s+)?(ba|z|k)?sh\b"#, options: .regularExpression) != nil { return "Télécharge et exécute un script" }
        if l.contains("osascript") { return "Lance un script AppleScript" }
        if l.range(of: #"base64\s+(-d|-D|--decode)"#, options: .regularExpression) != nil { return "Décode une charge cachée" }
        if l.range(of: #"(^|[\s'"=])(/tmp/|/private/tmp/|/private/var/tmp/|/users/shared/)"#, options: .regularExpression) != nil { return "Lance un programme depuis un dossier temporaire ou partagé" }
        if l.range(of: #"[/~]+[^\s'"]*/\.[a-z0-9_-]"#, options: .regularExpression) != nil { return "Lance un programme depuis un dossier caché" }
        return nil
    }

    /// Job lines only: comments, blank lines and variable assignments are skipped.
    static func entries(_ crontab: String) -> [(line: String, reason: String)] {
        crontab.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) == nil,
                  let reason = suspiciousReason(line) else { return nil }
            return (line, reason)
        }
    }

    /// Same line splitting as `entries` ("\r\n" is one Character in Swift, and a lone "\r" ends a line too).
    static func removing(_ line: String, from crontab: String) -> String {
        crontab.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != line }.joined(separator: "\n")
    }

    static func contains(_ line: String, in crontab: String) -> Bool {
        crontab.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == line }
    }

    /// A cron line for the logs: it may carry tokens (`curl -H "Authorization: …"`), so only its start is kept.
    static func excerpt(_ line: String, limit: Int = 40) -> String {
        let flat = line.map { $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true ? " " : String($0) }.joined()
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func group(crontab: String) -> ResultGroup {
        let items = entries(crontab).map { e in
            ResultItem(id: idPrefix + e.line, name: e.line, detail: "\(ThreatType.suspicious.label) · \(e.reason)",
                       symbol: "calendar.badge.clock", action: .custom(removeKey), autoSelect: false)
        }
        return ResultGroup(id: "prot.cron", title: "Tâches planifiées (cron) suspectes",
                           subtitle: "Lignes de votre crontab ; la crontab d'origine est sauvegardée avant tout retrait", symbol: "calendar.badge.clock", items: items)
    }

    /// Removes one line from the user's crontab, after saving the original next to the quarantine.
    static func remove(_ line: String, backupDir: URL) throws {
        let current = Shell.run("/usr/bin/crontab", ["-l"])
        guard current.ok else { throw RemovalError.failed(excerpt(line), "crontab illisible") }
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        try current.stdout.write(to: backupDir.appendingPathComponent("crontab \(stamp).txt"), atomically: true, encoding: .utf8)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-crontab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try removing(line, from: current.stdout).write(to: tmp, atomically: true, encoding: .utf8)
        let r = Shell.run("/usr/bin/crontab", [tmp.path])
        if !r.ok { throw RemovalError.failed(excerpt(line), r.stderr.isEmpty ? "code \(r.status)" : r.stderr) }
        // A removal is reported only once the line is really gone.
        if contains(line, in: Shell.run("/usr/bin/crontab", ["-l"]).stdout) { throw RemovalError.failed(excerpt(line), "ligne toujours présente dans la crontab") }
    }
}

/// Configuration profiles installed for the user (`profiles list`, no root; computer-level ones need root).
/// Read only: removing goes through System Settings.
enum ConfigProfiles {
    static let settingsURL = "x-apple.systempreferences:com.apple.Profiles-Settings.extension"

    /// Parses lines like `_computerlevel[1] attribute: profileIdentifier: com.example.x`.
    static func parse(_ output: String) -> [(identifier: String, name: String?)] {
        var order: [String] = []
        var attrs: [String: [String: String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: " attribute: ") else { continue }
            let owner = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = line[r.upperBound...]
            guard let colon = rest.firstIndex(of: ":") else { continue }
            if attrs[owner] == nil { order.append(owner) }
            attrs[owner, default: [:]][String(rest[..<colon])] = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return order.compactMap { o in attrs[o]?["profileIdentifier"].map { ($0, attrs[o]?["name"]) } }
    }

    static func group(output: String) -> ResultGroup {
        let profiles = parse(output)
        var items = profiles.map { p in
            ResultItem(id: "prot.profile.\(p.identifier)", name: p.name ?? p.identifier, detail: p.identifier,
                       symbol: "gearshape.2", action: .none, autoSelect: false)
        }
        if !items.isEmpty { items.append(settingsLink("prot.profile.settings", "Gérer les profils dans Réglages Système", settingsURL)) }
        return ResultGroup(id: "prot.profiles", title: "Profils de configuration",
                           subtitle: "Un profil inconnu peut imposer une page d'accueil, un proxy ou un certificat. Retrait depuis Réglages Système.",
                           symbol: "gearshape.2", items: items, autoSelect: false)
    }
}

/// An item that only opens a System Settings pane when run.
func settingsLink(_ id: String, _ title: String, _ url: String) -> ResultItem {
    ResultItem(id: id, name: title, detail: "Ouvre Réglages Système", symbol: "gear",
               action: .command(executable: "/usr/bin/open", arguments: [url], admin: false), autoSelect: false)
}
