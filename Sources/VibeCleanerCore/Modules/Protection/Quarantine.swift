import Foundation

/// Restorable quarantine: threats are moved here with a manifest instead of being deleted.
/// Root-owned items (system launchd plists, their programs) go to `adminRoot`, a folder only root can write,
/// through the administrator batch; their manifest stays in `root` with `admin: true`.
public struct Quarantine: Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public let id: String
        public let originalPath: String
        public let reason: String
        public let date: Date
        /// Stored in `adminRoot`: restoring or purging it asks for the administrator password.
        public var admin: Bool? = nil
        /// The entry of the launch plist that ran this program: restoring the plist restores it first.
        public var linkedTo: String? = nil
    }

    public let root: URL
    public let adminRoot: URL

    public init(root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/VibeCleaner/Quarantine"),
                adminRoot: URL = URL(fileURLWithPath: "/Library/Application Support/VibeCleaner/Quarantine")) {
        self.root = root
        self.adminRoot = adminRoot
    }

    /// The item goes into `<id>/payload/` so that a file named "manifest.json" cannot collide with the manifest.
    /// Entries of the older layout (`<id>/<name>`) restore as well.
    @discardableResult
    public func add(_ url: URL, reason: String, linkedTo: String? = nil) throws -> Entry {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id)
        let payload = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        do {
            try FileManager.default.moveItem(at: url, to: payload.appendingPathComponent(url.lastPathComponent))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        let entry = Entry(id: id, originalPath: url.path, reason: reason, date: Date(), linkedTo: linkedTo)
        try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("manifest.json"))
        return entry
    }

    /// The folder of an entry. Ids are the UUIDs `add` creates: anything else (empty, "..", a path) is refused.
    func entryDir(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/") else { throw RemovalError.failed(id, "identifiant de quarantaine invalide") }
        return root.appendingPathComponent(id)
    }

    /// The manifest of `id`, only when it names its own folder.
    func entry(_ id: String) throws -> Entry {
        let dir = try entryDir(id)
        let e = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        guard e.id == id else { throw RemovalError.failed(id, "manifeste de quarantaine incohérent") }
        return e
    }

    public func list() -> [Entry] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? entry($0.lastPathComponent) }.sorted { $0.date > $1.date }
    }

    // MARK: Restore

    /// Home folders a restore never writes into (data of other apps, keychains), Mail attachments excepted.
    static func sensitiveFolders(home: String) -> [String] {
        ["Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers", "Library/Group Containers", "Library/Keychains",
         "Library/Cookies", "Library/Application Support/com.apple.TCC", "Library/Mobile Documents", "Library/CloudStorage"].map { "\(home)/\($0)" }
    }

    static let mailDownloads = ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Library/Mail Downloads"]

    /// The manifest is writable by any process of the session: its destination is checked before anything moves.
    func destination(_ e: Entry, remover: SafeRemover) throws -> URL {
        let p = e.originalPath
        let url = URL(fileURLWithPath: p)
        guard p.hasPrefix("/"), url.standardizedFileURL.path == p, !p.contains("//"), !p.contains(where: \.isNewline),
              !["", ".", ".."].contains(url.lastPathComponent) else { throw RemovalError.protectedPath(p) }
        try remover.check(url)
        let home = remover.home
        let sensitive = Self.sensitiveFolders(home: home)
        let allowed = Self.mailDownloads.map { "\(home)/\($0)" }
        if FullDiskAccess.isUnder(p, sensitive) && !FullDiskAccess.isUnder(p, allowed) { throw RemovalError.protectedPath(p) }
        if (try? FileManager.default.attributesOfItem(atPath: p)) != nil {
            throw RemovalError.failed(p, "un élément existe déjà à cet emplacement")
        }
        return url
    }

    /// `launchctl bootstrap` arguments reloading a restored agent of the user: a plist directly in
    /// ~/Library/LaunchAgents, nil for anything else.
    static func bootstrapArguments(_ path: String, home: String, uid: uid_t = getuid()) -> [String]? {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "plist", url.deletingLastPathComponent().path == home + "/Library/LaunchAgents" else { return nil }
        return ["bootstrap", "gui/\(uid)", path]
    }

    /// Puts the item back where it was, with the programs set aside with it (`linkedTo`), then reloads a user agent
    /// through `launchctl` (injected by tests). Root-owned entries go through one administrator prompt and reload their job.
    public func restore(_ id: String, remover: SafeRemover = SafeRemover(),
                        launchctl: ([String]) -> Void = { Shell.run("/bin/launchctl", $0) }) throws {
        try restore(id, remover: remover, launchctl: launchctl, visited: [])
    }

    /// `visited`: entries already on the way, so that a manifest edited into a cycle (A → B → A) cannot recurse forever.
    private func restore(_ id: String, remover: SafeRemover, launchctl: ([String]) -> Void, visited: Set<String>) throws {
        let e = try entry(id)
        let dir = try entryDir(id)
        let original = try destination(e, remover: remover)
        // Programs first, so that the reloaded job finds them. One that cannot come back stays listed here.
        if !remover.dryRun {
            let seen = visited.union([id])
            for program in list() where program.linkedTo == id && !seen.contains(program.id) {
                try? restore(program.id, remover: remover, launchctl: launchctl, visited: seen)
            }
        }
        if e.admin == true {
            let command = try adminRestoreCommand(e)
            if remover.dryRun { return }
            try runAdmin(ResultItem(id: e.id, name: original.lastPathComponent, action: .command(executable: command[0], arguments: Array(command.dropFirst()), admin: true)), remover: remover)
            try FileManager.default.removeItem(at: dir)
            return
        }
        let inPayload = dir.appendingPathComponent("payload").appendingPathComponent(original.lastPathComponent)
        let older = dir.appendingPathComponent(original.lastPathComponent)
        let fm = FileManager.default
        guard let source = [inPayload, older].first(where: { (try? fm.attributesOfItem(atPath: $0.path)) != nil }) else {
            throw RemovalError.failed(e.originalPath, "élément absent de la quarantaine")
        }
        if remover.dryRun { return }
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: original)
        try fm.removeItem(at: dir)
        if let args = Self.bootstrapArguments(original.path, home: remover.home) { launchctl(args) }
    }

    /// Deletes an entry for good.
    public func purge(_ id: String, remover: SafeRemover = SafeRemover()) throws {
        let dir = try entryDir(id)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw RemovalError.failed(id, "entrée de quarantaine invalide") }
        try remover.check(dir)
        if let e = try? entry(id), e.admin == true {
            let item = ResultItem(id: id, name: URL(fileURLWithPath: e.originalPath).lastPathComponent,
                                  action: .command(executable: "/bin/sh", arguments: ["-c", Self.adminPurgeScript, "sh", adminRoot.path, id], admin: true))
            if remover.dryRun { return }
            try runAdmin(item, remover: remover)
        }
        if remover.dryRun { return }
        try FileManager.default.removeItem(at: dir)
    }

    func runAdmin(_ item: ResultItem, remover: SafeRemover) throws {
        let r = ActionExecutor(remover: remover).run([item])
        if let f = r.failures.first { throw RemovalError.failed(item.name, f.reason) }
    }

    // MARK: Root items

    /// launchd domain of a plist of /Library: daemons in `system`, agents in the user's GUI session.
    public static func launchdDomain(_ path: String, uid: uid_t = getuid()) -> String? {
        if path.hasPrefix("/Library/LaunchDaemons/") { return "system" }
        if path.hasPrefix("/Library/LaunchAgents/") { return "gui/\(uid)" }
        return nil
    }

    /// $1 item, $2 its physical parent, $3 root zone, $4 entry id, $5 launchd domain ("" = none), $6 launchctl.
    /// The item is reached from its checked parent (no swapped link on the way, as in `ActionExecutor.parentGuard`),
    /// and the entry folder is created by root inside a root-owned zone, so nothing can redirect the move.
    static let adminAddScript = ActionExecutor.parentGuard + "\n" + """
    z="$3"; d="$z/$4"
    [ -L "$z" ] && exit 1
    /bin/mkdir -p -m 700 "$z" && [ ! -L "$z" ] && /bin/mkdir -m 700 "$d" || exit 1
    [ -z "$5" ] || "$6" bootout "$5" "$1" >/dev/null 2>&1
    /bin/mv -n -- "$p" "$d/" && [ ! -e "$p" ] && [ ! -L "$p" ] && printf '%s' "$1" > "$d/.origin" && exit 0
    /bin/rmdir "$d" 2>/dev/null; exit 1
    """

    /// $1 stored item, $2 destination, $3 launchd domain ("" = none), $4 the only owner besides root allowed for an
    /// ancestor of the destination (0 in production: no folder of the user, no link, can redirect the move), $5 launchctl.
    static let adminRestoreScript = """
    { [ -e "$2" ] || [ -L "$2" ]; } && exit 1
    [ "$(/bin/cat "$(/usr/bin/dirname "$1")/.origin" 2>/dev/null)" = "$2" ] || exit 1
    p=$(/usr/bin/dirname "$2")
    while [ "$p" != / ]; do [ -L "$p" ] && exit 1; o=$(/usr/bin/stat -f %u "$p"); [ "$o" = 0 ] || [ "$o" = "$4" ] || exit 1; p=$(/usr/bin/dirname "$p"); done
    /bin/mv -n -- "$1" "$2" && [ ! -e "$1" ] && [ ! -L "$1" ] || exit 1
    /bin/rm -f "$(/usr/bin/dirname "$1")/.origin"; /bin/rmdir "$(/usr/bin/dirname "$1")" 2>/dev/null
    [ -z "$3" ] || "$5" bootstrap "$3" "$2" >/dev/null 2>&1
    exit 0
    """

    /// $1 root zone, $2 entry id.
    static let adminPurgeScript = """
    [ -L "$1" ] && exit 1
    [ -L "$1/$2" ] && exit 1
    /bin/rm -rf -- "$1/$2"
    """

    /// The admin command moving the root-owned `url` into `adminRoot/<id>/`, after a bootout in `domain`.
    /// Refused when a parent of `url` is a symbolic link: root never moves through a link that could have been swapped.
    public func adminAddCommand(_ url: URL, id: String, domain: String?, launchctl: String = "/bin/launchctl") throws -> [String] {
        guard let parent = ActionExecutor.physicalParent(url) else {
            throw RemovalError.failed(url.path, "un dossier parent est un lien symbolique")
        }
        return ["/bin/sh", "-c", Self.adminAddScript, "sh", url.path, parent, adminRoot.path, id, domain ?? "", launchctl]
    }

    /// Records an item moved by `adminAddCommand`, once the administrator batch succeeded (no orphan entry otherwise).
    @discardableResult
    /// `linkedTo`: the entry of the plist that launched this program, restored with it.
    public func recordAdmin(id: String, originalPath: String, reason: String, linkedTo: String? = nil) throws -> Entry {
        let dir = try entryDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = Entry(id: id, originalPath: originalPath, reason: reason, date: Date(), admin: true, linkedTo: linkedTo)
        try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("manifest.json"))
        return entry
    }

    func adminRestoreCommand(_ e: Entry, ownerUID: uid_t = 0, launchctl: String = "/bin/launchctl") throws -> [String] {
        _ = try entryDir(e.id)
        let name = URL(fileURLWithPath: e.originalPath).lastPathComponent
        let stored = adminRoot.appendingPathComponent(e.id).appendingPathComponent(name)
        return ["/bin/sh", "-c", Self.adminRestoreScript, "sh", stored.path, e.originalPath,
                Self.launchdDomain(e.originalPath) ?? "", String(ownerUID), launchctl]
    }
}
