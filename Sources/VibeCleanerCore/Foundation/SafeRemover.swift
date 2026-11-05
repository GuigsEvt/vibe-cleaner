import Foundation

public enum RemovalMode: String, Codable, Sendable, CaseIterable {
    case trash, permanent
}

public enum RemovalError: Error, LocalizedError, Equatable {
    case protectedPath(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .protectedPath(let p): "Refusé, chemin protégé : \(p)"
        case .failed(let p, let why): "Échec de suppression de \(p) : \(why)"
        }
    }
}

public struct RemovalReport: Sendable {
    public var removed: [URL] = []
    public var freedBytes: Int64 = 0
    public var failures: [(URL, String)] = []

    public init() {}
}

/// Last line of defence before anything leaves the disk. Every module deletes through here.
public struct SafeRemover: Sendable {
    public var dryRun: Bool
    public var userExclusions: [String]
    public let home: String

    public init(dryRun: Bool = false, userExclusions: [String] = [], home: String = NSHomeDirectory()) {
        self.dryRun = dryRun
        self.userExclusions = userExclusions
        self.home = home
    }

    /// Directories that may never be removed themselves; their contents may be.
    var protectedRoots: Set<String> {
        let h = home
        // `resolvingSymlinksInPath` turns existing /private/var and /private/tmp paths into /var and /tmp: both spellings.
        return ["/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var", "/private/tmp", "/var", "/tmp",
                "/opt", "/opt/homebrew", "/usr/local",
                h, "\(h)/Library", "\(h)/Library/Caches", "\(h)/Library/Logs", "\(h)/Library/Application Support",
                "\(h)/Library/Preferences", "\(h)/Library/Containers", "\(h)/Library/Group Containers",
                "\(h)/Library/Mail", "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage",
                "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
                "\(h)/.Trash"]
    }

    /// Trees that are never touched at all.
    static let forbiddenPrefixes = ["/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share",
                                    "/bin", "/sbin", "/Library/Apple", "/private/var/db", "/var/db", "/dev",
                                    "/private/etc", "/etc", "/Library/Keychains", "/Library/Security",
                                    "/private/var/root", "/var/root", "/Library/Preferences/SystemConfiguration",
                                    "/Library/Application Support/com.apple.TCC", "/private/var/vm", "/var/vm",
                                    "/private/var/protected", "/var/protected"]

    /// Folders refused wherever they are, external disks included: Time Machine backups and the volume's own
    /// Spotlight index, file system event log and document versions.
    static let forbiddenComponents: Set<String> = ["Backups.backupdb", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"]

    /// Home trees never touched at all (`*` stands for one path component): keychains, Messages, account
    /// databases, Mail's own database, Photos libraries and the documents apps keep in their sandbox.
    /// Keys and credentials (SSH, GPG, cloud and Kubernetes tools, password store), the privacy database (TCC),
    /// and the Calendar, Contacts, Notes and Reminders data too: the app may hold Full Disk Access.
    static let forbiddenHomePatterns = ["Library/Keychains", "Library/Messages", "Library/Accounts", "Library/Mail/V*/MailData",
                                        "Pictures/*.photoslibrary", "Library/Containers/*/Data/Documents",
                                        ".ssh", ".gnupg", "Library/Application Support/com.apple.TCC",
                                        ".aws", ".azure", ".kube", ".netrc", ".password-store", ".config/gcloud", ".config/gh",
                                        "Library/Calendars", "Library/Application Support/AddressBook",
                                        "Library/Group Containers/group.com.apple.notes", "Library/Group Containers/group.com.apple.reminders"]

    /// Known regenerable caches inside a forbidden home tree (Youku keeps its player cache in Data/Documents).
    static let allowedHomePaths = ["Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE"]

    /// True when `path` is `pattern` or inside it, comparing component by component with fnmatch(3).
    static func isUnder(_ path: String, pattern: String) -> Bool {
        let p = path.split(separator: "/", omittingEmptySubsequences: true)
        let q = pattern.split(separator: "/", omittingEmptySubsequences: true)
        guard p.count >= q.count else { return false }
        return zip(p, q).allSatisfy { $1.contains("*") ? fnmatch(String($1), String($0), 0) == 0 : $0 == $1 }
    }

    /// Same refusal as `check` for a path Radar offers (no user exclusions): protected roots and forbidden trees.
    public static func isProtected(path: String, home: String = NSHomeDirectory()) -> Bool {
        do { try SafeRemover(home: home).check(URL(fileURLWithPath: path)); return false } catch { return true }
    }

    /// A symbolic link directly inside a trash (~/.Trash, .Trashes/<uid>): removing it removes the link only,
    /// so its own (unresolved) path is checked rather than its target.
    static func isLinkInTrash(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { return false }
        let parent = url.deletingLastPathComponent()
        return parent.lastPathComponent == ".Trash" || parent.lastPathComponent == ".Trashes"
            || parent.deletingLastPathComponent().lastPathComponent == ".Trashes"
    }

    /// The spellings a path can take: as given, with symlinks resolved (drops /private), and realpath(3) (keeps it).
    static func forms(_ path: String) -> Set<String> {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return [url.path, url.resolvingSymlinksInPath().path, Junk.realPath(url.path)]
    }

    public func check(_ url: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var paths = Self.forms(url.path)
        if Self.isLinkInTrash(url.standardizedFileURL) {
            let link = url.standardizedFileURL
            paths = Set(Self.forms(link.deletingLastPathComponent().path).map { ($0 as NSString).appendingPathComponent(link.lastPathComponent) })
        }
        // Both sides in every spelling: a home reached through a symlink stays protected.
        let roots = Set(protectedRoots.flatMap(Self.forms))
        if !paths.isDisjoint(with: roots) { throw RemovalError.protectedPath(path) }
        for p in paths {
            for prefix in Self.forbiddenPrefixes where p == prefix || p.hasPrefix(prefix + "/") {
                throw RemovalError.protectedPath(path)
            }
        }
        for p in paths where p.split(separator: "/").contains(where: { Self.forbiddenComponents.contains(String($0)) }) {
            throw RemovalError.protectedPath(path)
        }
        // Every spelling on its own: an allowed path that is a symlink into a forbidden tree is still refused.
        for h in Self.forms(home) {
            for p in paths where Self.forbiddenHomePatterns.contains(where: { Self.isUnder(p, pattern: "\(h)/\($0)") })
                && !Self.allowedHomePaths.contains(where: { Self.isUnder(p, pattern: "\(h)/\($0)") }) {
                throw RemovalError.protectedPath(path)
            }
        }
        for ex in userExclusions {
            for e in Self.forms((ex as NSString).expandingTildeInPath) {
                if paths.contains(where: { $0 == e || $0.hasPrefix(e + "/") }) { throw RemovalError.protectedPath(path) }
            }
        }
    }

    public func remove(_ urls: [URL], mode: RemovalMode) -> RemovalReport {
        var report = RemovalReport()
        for url in urls {
            do {
                try check(url)
                // A simulation must not report a file that is not there (lstat: a broken symlink counts).
                if dryRun, (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil {
                    throw RemovalError.failed(url.path, "introuvable")
                }
                // A permanent deletion never goes through a linked parent: a cache folder that is a link to Documents
                // would otherwise delete the real documents for good. The Trash keeps a way back, so it is allowed there.
                if mode == .permanent, ActionExecutor.physicalParent(url) == nil {
                    throw RemovalError.failed(url.path, "un dossier parent est un lien symbolique")
                }
                let size = FileSizer.size(of: url)
                if !dryRun {
                    switch mode {
                    case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    case .permanent: try FileManager.default.removeItem(at: url)
                    }
                }
                report.removed.append(url)
                report.freedBytes += size
            } catch {
                report.failures.append((url, error.localizedDescription))
            }
        }
        return report
    }
}
