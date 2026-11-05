import Foundation

/// Mail attachments, trash bins and old Slack downloads.
enum MailTrashScanner {

    // MARK: Mail

    /// Latest ~/Library/Mail/V<n>.
    static func mailRoot(_ s: JunkScope) -> URL? {
        Junk.children(s.lib("Mail")).compactMap { url -> (Int, URL)? in
            let n = url.lastPathComponent
            guard n.hasPrefix("V"), let v = Int(n.dropFirst()) else { return nil }
            return (v, url)
        }.max { $0.0 < $1.0 }?.1
    }

    /// Unmodified since download: creation date equals modification date.
    static func isUntouched(_ url: URL) -> Bool {
        guard let c = Junk.created(url), let m = Junk.modified(url) else { return false }
        return abs(c.timeIntervalSince(m)) < 1
    }

    // MARK: Accounts (Accounts4.sqlite)

    struct MailAccount: Equatable {
        enum Kind: Equatable { case imap, icloud, pop, exchange, other }
        let kind: Kind
        let title: String?
        let active: Bool
        /// IMAP and iCloud keep every message and attachment on the server.
        var recoverable: Bool { active && (kind == .imap || kind == .icloud) }
    }

    static let accountsSQL = """
        SELECT a.ZIDENTIFIER AS id, t.ZIDENTIFIER AS type, a.ZACCOUNTDESCRIPTION AS title, a.ZUSERNAME AS user, a.ZACTIVE AS active \
        FROM ZACCOUNT a LEFT JOIN ZACCOUNTTYPE t ON a.ZACCOUNTTYPE = t.Z_PK
        """

    static func accountKind(_ type: String) -> MailAccount.Kind {
        let t = type.lowercased()
        if t.contains("pop") { return .pop }
        if t.contains("exchange") || t.contains("ews") { return .exchange }
        if t.contains("imap") { return .imap }
        if t == "com.apple.account.appleaccount" || t.contains("icloud") { return .icloud }
        return .other
    }

    /// Mail folder name (account UUID) → account, from rows of `accountsSQL`.
    static func mailAccounts(_ rows: [[String: String]]) -> [String: MailAccount] {
        var out: [String: MailAccount] = [:]
        for r in rows {
            guard let id = r["id"] else { continue }
            out[id] = MailAccount(kind: accountKind(r["type"] ?? ""), title: r["title"] ?? r["user"], active: r["active"] != "0")
        }
        return out
    }

    /// Nil when the database cannot be read (no Full Disk Access): callers fall back to no account filter.
    static func mailAccounts(_ s: JunkScope) -> [String: MailAccount]? {
        SQLite.rows(s.lib("Accounts/Accounts4.sqlite"), accountsSQL).map(mailAccounts)
    }

    static func mail(_ s: JunkScope) -> ResultGroup {
        mail(s, accounts: mailAccounts(s))
    }

    static func mail(_ s: JunkScope, accounts: [String: MailAccount]?) -> ResultGroup {
        var g = ResultGroup(id: "cleanup.mail", title: "Pièces jointes Mail",
                            subtitle: "Pièces jointes téléchargées, récupérables depuis le serveur. Nécessite l'accès complet au disque.", symbol: "paperclip")
        let mailOpen = s.isRunning("com.apple.mail")
        let note = mailOpen ? "Mail est ouvert — " : ""

        if let root = mailRoot(s) {
            for account in Junk.children(root) where Junk.isDirectory(account) && account.lastPathComponent != "MailData" {
                if Task.isCancelled { break }
                let name = account.lastPathComponent
                // "Mailboxes" holds local (On My Mac) mail: nothing to download again. With the accounts database,
                // only IMAP and iCloud accounts are selected; POP, Exchange and unknown accounts are listed unchecked.
                // Without it (no Full Disk Access) nothing is selected: a POP attachment cannot be downloaded again.
                let local = name == "Mailboxes"
                let info = accounts?[name]
                let recoverable = !local && (accounts == nil || info?.recoverable == true)
                let why = local ? "" : accounts == nil ? "Type de compte inconnu — " : recoverable ? "" : info == nil ? "Compte inconnu — " : "Compte non IMAP — "
                // Trash mailboxes of recoverable accounts are offered whole under "Corbeilles de Mail".
                let items = attachmentFolders(in: account, skippingTrash: accounts != nil && recoverable).compactMap {
                    s.item($0, name: "Message \($0.lastPathComponent)", detail: note + why + $0.deletingLastPathComponent().path,
                           mode: .trash, auto: recoverable && accounts != nil && !mailOpen)
                }
                if !items.isEmpty {
                    g.groups.append(ResultGroup(id: "cleanup.mail.\(name)",
                                                title: local ? "Sur mon Mac" : info?.title ?? "Compte \(name.prefix(8))", symbol: "tray", items: items))
                }
            }
        }

        var downloads: [ResultItem] = []
        for dir in [s.h("Library/Mail Downloads"), s.lib("Containers/com.apple.mail/Data/Library/Mail Downloads")] {
            for entry in Junk.children(dir) {
                // UUID folders wrap one download each.
                let files = UUID(uuidString: entry.lastPathComponent) != nil && Junk.isDirectory(entry) ? Junk.children(entry) : [entry]
                for f in files {
                    let untouched = isUntouched(f)
                    if let item = s.item(f, detail: untouched ? nil : "Modifié après le téléchargement — \(f.deletingLastPathComponent().path)",
                                         mode: .trash, auto: untouched && !mailOpen) { downloads.append(item) }
                }
            }
        }
        if !downloads.isEmpty { g.groups.append(ResultGroup(id: "cleanup.mail.downloads", title: "Téléchargements de Mail", symbol: "arrow.down.circle", items: downloads)) }
        return g
    }

    /// Children (one per message) of every folder named "Attachments" under an account.
    static func attachmentFolders(in account: URL, skippingTrash: Bool = false) -> [URL] {
        guard let e = Junk.fm.enumerator(at: account, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
                                         errorHandler: { _, _ in true }) else { return [] }
        var out: [URL] = []
        var n = 0
        for case let url as URL in e {
            n += 1
            if n % 2000 == 0 && Task.isCancelled { break }
            if skippingTrash && trashMailboxes.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard url.lastPathComponent.lowercased() == "attachments", Junk.isDirectory(url) else { continue }
            e.skipDescendants()
            out += Junk.children(url)
        }
        return out
    }

    // MARK: Trash bins

    static func trash(_ s: JunkScope) -> ResultGroup {
        var g = ResultGroup(id: "cleanup.trash", title: "Corbeilles",
                            subtitle: "Vide définitivement les corbeilles de votre Mac", symbol: "trash")
        func bin(_ id: String, _ title: String, _ dir: URL, auto: Bool = true) {
            let items = Junk.children(dir, hidden: true).compactMap { s.item($0, mode: .permanent, auto: auto, keepEmpty: true) }
            if !items.isEmpty { g.groups.append(ResultGroup(id: "cleanup.trash.\(id)", title: title, symbol: "trash", items: items)) }
        }
        bin("user", "Corbeille", s.h(".Trash"))
        // iCloud trashes propagate to every device: not selected by default. Several paths can be the same folder.
        var seen = Set<String>()
        for (id, title, dir) in iCloudTrashes(s) where Junk.exists(dir) && seen.insert(Junk.realPath(dir.path)).inserted {
            bin(id, title, dir, auto: false)
        }
        if let messages = mailTrashes(s, accounts: mailAccounts(s)) { g.groups.append(messages) }
        guard s.system else { return g }
        rootTrash(&g, s)
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey, .volumeNameKey]
        let uid = getuid()
        for vol in Junk.fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard vol.path.hasPrefix("/Volumes/"), let v = try? vol.resourceValues(forKeys: Set(keys)),
                  v.volumeIsLocal == true, v.volumeIsReadOnly != true, v.volumeIsBrowsable == true else { continue }
            bin("volume.\(vol.lastPathComponent)", "Corbeille de « \(v.volumeName ?? vol.lastPathComponent) »",
                vol.appendingPathComponent(".Trashes/\(uid)"))
        }
        return g
    }

    /// Root-owned items Vibe Cleaner set aside (`ActionExecutor.rootTrash`): one folder per item, removed in the admin batch.
    static func rootTrash(_ g: inout ResultGroup, _ s: JunkScope, root: URL = URL(fileURLWithPath: ActionExecutor.rootTrash)) {
        let items = Junk.children(root, hidden: true).compactMap { dir -> ResultItem? in
            let inner = Junk.children(dir, hidden: true).first?.lastPathComponent ?? dir.lastPathComponent
            return s.item(dir, name: inner, detail: "Élément système mis de côté par Vibe Cleaner le \(Junk.format(Junk.modified(dir)))",
                          mode: .permanent, auto: false, keepEmpty: true)
        }
        if !items.isEmpty {
            g.groups.append(ResultGroup(id: "cleanup.trash.admin", title: "Corbeille administrateur de Vibe Cleaner",
                                        subtitle: "Éléments root retirés par Vibe Cleaner (droits administrateur)", symbol: "trash", items: items))
        }
    }

    /// iCloud Drive, the Mobile Documents root and each app container's Documents/.Trash.
    static func iCloudTrashes(_ s: JunkScope) -> [(String, String, URL)] {
        let docs = s.lib("Mobile Documents")
        var out: [(String, String, URL)] = [
            ("icloud", "Corbeille iCloud Drive", docs.appendingPathComponent("com~apple~CloudDocs/.Trash")),
            ("icloud.cloudStorage", "Corbeille iCloud Drive (CloudStorage)", s.lib("CloudStorage/iCloud Drive/.Trash")),
            ("icloud.root", "Corbeille iCloud", docs.appendingPathComponent(".Trash")),
        ]
        for container in Junk.children(docs) where Junk.isDirectory(container) {
            let name = container.lastPathComponent
            let app = name.components(separatedBy: "~").last ?? name
            out.append(("icloud.\(name)", "Corbeille iCloud de « \(app) »", container.appendingPathComponent("Documents/.Trash")))
        }
        return out
    }

    // MARK: Mail trashes

    static let trashMailboxes: Set<String> = ["Deleted Messages.mbox", "Trash.mbox", "Corbeille.mbox", "Bin.mbox", "Papierkorb.mbox", "Messages supprimés.mbox"]

    /// Local copies of deleted messages in IMAP/iCloud trash mailboxes. Only offered when the
    /// accounts database confirms the account keeps mail on the server: removing the copies frees space on
    /// the Mac, the messages stay in the server-side trash and Mail downloads them again if opened.
    /// Never selected, and moved to the Trash rather than deleted.
    static func mailTrashes(_ s: JunkScope, accounts: [String: MailAccount]?) -> ResultGroup? {
        guard let accounts, let root = mailRoot(s) else { return nil }
        let note = s.isRunning("com.apple.mail") ? "Mail est ouvert — " : ""
        var items: [ResultItem] = []
        for account in Junk.children(root) where accounts[account.lastPathComponent]?.recoverable == true {
            let title = accounts[account.lastPathComponent]?.title ?? String(account.lastPathComponent.prefix(8))
            for box in Junk.children(account) where trashMailboxes.contains(box.lastPathComponent) {
                for data in Junk.glob(box, "*/Data") {
                    if let item = s.item(data, name: "\(box.deletingPathExtension().lastPathComponent) — \(title)",
                                         detail: note + "Copies locales des messages supprimés (restent sur le serveur) — \(data.path)",
                                         mode: .trash, auto: false) { items.append(item) }
                }
            }
        }
        return items.isEmpty ? nil : ResultGroup(id: "cleanup.trash.mail", title: "Corbeilles de Mail", symbol: "envelope", items: items, autoSelect: false)
    }

    // MARK: Slack downloads

    static let slackAge: TimeInterval = 30 * 86_400

    static func slackDownloads(_ s: JunkScope) -> ResultGroup {
        var items: [ResultItem] = []
        var seen = Set<String>()
        let stores = [s.lib("Application Support/Slack/storage"),
                      s.lib("Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/storage")]
        for store in stores {
            guard let data = try? Data(contentsOf: store.appendingPathComponent("slack-downloads")),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for d in downloadRecords(json) {
                guard seen.insert(d.path).inserted else { continue }
                let url = URL(fileURLWithPath: d.path)
                let old = d.start.map { Date().timeIntervalSince($0) > slackAge } ?? false
                if let item = s.item(url, detail: "Téléchargé le \(Junk.format(d.start)) — \(url.deletingLastPathComponent().path)",
                                     mode: .trash, auto: old && isSlackDownload(url, start: d.start, s)) { items.append(item) }
            }
        }
        return ResultGroup(id: "cleanup.system.slack", title: "Téléchargements Slack",
                           subtitle: "Fichiers téléchargés depuis Slack ; ceux de plus de 30 jours sont sélectionnés", symbol: "bubble.left.and.bubble.right", items: items)
    }

    /// The record's file is still the one Slack downloaded: a regular file under ~/Downloads created within a day
    /// of `startTime`. The path in Slack's JSON may since name another file (renamed, replaced, moved elsewhere).
    static func isSlackDownload(_ url: URL, start: Date?, _ s: JunkScope) -> Bool {
        guard let start, let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]), v.isRegularFile == true,
              let created = v.creationDate, abs(created.timeIntervalSince(start)) <= 86_400 else { return false }
        let downloads = s.h("Downloads")
        let path = Junk.realPath(url.path)
        return [downloads.path, Junk.realPath(downloads.path)].contains { path.hasPrefix($0 + "/") }
    }

    /// Finished download records anywhere in Slack's JSON (`downloadPath`, `startTime` in ms, `downloadState`).
    static func downloadRecords(_ json: Any) -> [(path: String, start: Date?)] {
        if let array = json as? [Any] { return array.flatMap(downloadRecords) }
        guard let dict = json as? [String: Any] else { return [] }
        if let path = dict["downloadPath"] as? String {
            let state = (dict["downloadState"] as? String)?.lowercased() ?? ""
            guard !["progressing", "paused", "in_progress", "pending"].contains(state) else { return [] }
            let t = (dict["startTime"] as? NSNumber)?.doubleValue
            return [(path, t.map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) })]
        }
        return dict.values.flatMap(downloadRecords)
    }
}
