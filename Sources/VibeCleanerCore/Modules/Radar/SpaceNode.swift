import Foundation

/// A file or folder in a Radar tree. Built bottom-up by `SpaceScanner`; once returned it is only
/// mutated by `detach()`, on the caller's actor (the UI's main actor).
public final class SpaceNode: @unchecked Sendable, Identifiable {
    public let name: String
    /// Allocated bytes (st_blocks), cumulated for folders and packages. Hard links counted once per scan.
    public private(set) var size: Int64
    /// Number of non-directory entries below (1 for a file).
    public private(set) var fileCount: Int
    public let isDirectory: Bool
    /// Bundle (.app, .photoslibrary...) shown as a single item: size aggregated, no children.
    public let isPackage: Bool
    /// Sorted by decreasing size.
    public private(set) var children: [SpaceNode]
    public private(set) weak var parent: SpaceNode?
    /// st_mtime in seconds since 1970, 0 when unknown.
    let mtime: Int
    private let rootURL: URL?

    init(name: String, size: Int64, fileCount: Int, isDirectory: Bool, isPackage: Bool = false,
         children: [SpaceNode] = [], mtime: Int = 0, rootURL: URL? = nil) {
        self.name = name
        self.size = size
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.children = children.sorted(by: Self.order)
        self.mtime = mtime
        self.rootURL = rootURL
        for child in children { child.parent = self }
    }

    static func order(_ a: SpaceNode, _ b: SpaceNode) -> Bool { a.size != b.size ? a.size > b.size : a.name < b.name }

    public var modificationDate: Date? { mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil }

    /// Removes self from the tree after a deletion: its size and file count are subtracted from every
    /// ancestor and siblings are re-sorted, so the map updates without a rescan.
    public func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var node: SpaceNode? = parent
        while let n = node {
            n.size -= size
            n.fileCount -= fileCount
            n.parent?.children.sort(by: Self.order)
            node = n.parent
        }
        self.parent = nil
    }

    /// Deepest node still in the tree on the way to `path` (self if nothing below matches).
    public func nearest(to path: String) -> SpaceNode {
        var node = self
        while let c = node.child(toward: path) { node = c }
        return node
    }

    /// Child that is `path` or contains it.
    private func child(toward path: String) -> SpaceNode? {
        let mine = self.path
        let prefix = mine.hasSuffix("/") ? mine : mine + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let next = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init)
        if let c = children.first(where: { $0.rootURL == nil && $0.name == next }) { return c }
        // Roots of a multi-root scan keep their own absolute URL.
        return children.first { $0.rootURL != nil && (path == $0.path || path.hasPrefix($0.path + "/")) }
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }

    public var url: URL {
        if let rootURL { return rootURL }
        guard let parent else { return URL(fileURLWithPath: name) }
        return parent.url.appendingPathComponent(name, isDirectory: isDirectory)
    }

    public var path: String { url.path }

    /// Ancestors from the scan root down to self (breadcrumb).
    public var ancestry: [SpaceNode] {
        var chain: [SpaceNode] = [self]
        while let p = chain.last?.parent { chain.append(p) }
        return chain.reversed()
    }

    /// Essential system location: shown, never deletable.
    public var isProtected: Bool { Self.isProtected(path: path) }

    /// Finds a descendant by absolute path.
    public func node(at path: String) -> SpaceNode? {
        if path == self.path { return self }
        return child(toward: path)?.node(at: path)
    }

    /// Selected paths minus those already inside another selected folder, so nothing is counted or removed twice.
    public static func outermost(_ paths: Set<String>) -> [String] {
        paths.filter { p in !paths.contains { q in q != p && p.hasPrefix(q.hasSuffix("/") ? q : q + "/") } }.sorted()
    }

    /// True for an item synced by iCloud Drive or a File Provider (Google Drive, OneDrive, Dropbox…): moving it to
    /// the Trash deletes it from the cloud and from the user's other devices too. Reads no file data.
    public static func isCloudSynced(path: String, home: String = NSHomeDirectory()) -> Bool {
        let roots = [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"]
        if roots.contains(where: { path.hasPrefix($0 + "/") }) { return true }
        // Desktop and Documents synced by iCloud.
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    static let protectedSubtrees = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library/Apple",
                                    "/dev", "/cores", "/etc", "/var", "/tmp"]

    static func isProtected(path: String, home: String = NSHomeDirectory()) -> Bool {
        let exact: Set<String> = ["/", "/Library", "/Applications", "/Users", "/Volumes", "/opt",
                                  home, home + "/Library", home + "/Library/Mobile Documents",
                                  home + "/Library/Mobile Documents/com~apple~CloudDocs"]
        if exact.contains(path) { return true }
        // A File Provider domain root (Google Drive, OneDrive...) or the folder holding them.
        let storage = home + "/Library/CloudStorage"
        if path == storage || (path.hasPrefix(storage + "/") && !path.dropFirst(storage.count + 1).contains("/")) { return true }
        if protectedSubtrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        // Whatever SafeRemover would refuse anyway (protected roots, forbidden trees such as keychains or Photos libraries).
        return SafeRemover.isProtected(path: path, home: home)
    }
}
