import Darwin
import Foundation
import Synchronization

/// Fast parallel disk walker for Radar. Never writes to disk.
///
/// - Metadata: `readdir` + `fstatat(AT_SYMLINK_NOFOLLOW)` per entry (one syscall, no Foundation boxing).
///   Size = `st_blocks * 512` (allocated, compression and sparse files included).
/// - Volumes: only entries whose `st_dev` belongs to the scanned volume are traversed.
/// - APFS firmlinks: `/` is the sealed System volume; `/Users`, `/Applications`, `/Library`, `/private`...
///   are firmlinks into the Data volume, which also appears at `/System/Volumes/Data`. When scanning `/`
///   we accept both devices (System + Data) and skip `/System/Volumes/Data`, so Data is counted once,
///   under its user-visible paths. Other `/System/Volumes/*` (VM, Preboot, Update...) are other devices
///   and excluded. Scanning `/System/Volumes/Data` directly also works (single device).
/// - Symlinks are never followed (counted with their own tiny size). Packages are walked but kept childless.
/// - Hard links: regular files with `st_nlink > 1` are counted once per `(st_dev, st_ino)`.
/// - Cloud placeholders: `lstat` never materializes a dataless file (only reading data or listing a dataless
///   folder does). Folders flagged `SF_DATALESS` are not listed, and each listing runs with the thread's
///   dataless materialization policy set to off, so a scan never triggers a download from iCloud or a File Provider.
/// - Parallelism: folders at depth 0 and 1 fan out into task groups (bounded width); deeper is sequential.
public actor SpaceScanner {
    public typealias Progress = @Sendable (_ scannedBytes: Int64, _ files: Int, _ currentPath: String) -> Void

    public static let defaultRoot = URL(fileURLWithPath: "/")
    static let parallelDepth = 2
    static let skippedSuffixes = ["/Library/Reminders"]
    static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "photoslibrary", "musiclibrary",
        "tvlibrary", "photolibrary", "aplibrary", "fcpbundle", "logicx", "band", "imovielibrary", "rtfd",
        "pages", "numbers", "key", "xcarchive", "playground", "docset", "pkg", "mpkg", "sparsebundle",
        "lrlibrary", "lrdata", "theater", "dvdmedia", "prefpane", "qlgenerator", "mdimporter", "saver", "wdgt",
    ]

    public init() {}

    /// Cloud placeholder whose content (or listing, for a folder) is not on this Mac.
    static func isDataless(_ flags: UInt32) -> Bool { flags & UInt32(SF_DATALESS) != 0 }

    public func scan(root: URL, name: String? = nil, progress: @escaping Progress) async throws -> SpaceNode {
        try Task.checkCancellation()
        let rootPath = root.standardizedFileURL.path
        var st = stat()
        guard lstat(rootPath, &st) == 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: rootPath]) }
        var devices: Set<dev_t> = [st.st_dev]
        var skipped: Set<String> = []
        if rootPath == "/" {
            var data = stat()
            if lstat("/System/Volumes/Data", &data) == 0 { devices.insert(data.st_dev) }
            skipped.insert("/System/Volumes/Data")
        }
        let walk = Walk(devices: devices, skipped: skipped, progress: progress)
        let node: SpaceNode
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let r = await walk.directory(path: rootPath, depth: 0)
            node = SpaceNode(name: name ?? root.lastPathComponent, size: r.size, fileCount: r.files, isDirectory: true,
                             isPackage: false, children: r.children, mtime: st.st_mtimespec.tv_sec,
                             rootURL: URL(fileURLWithPath: rootPath, isDirectory: true))
        } else {
            node = SpaceNode(name: name ?? root.lastPathComponent, size: Int64(st.st_blocks) * 512, fileCount: 1,
                             isDirectory: false, mtime: st.st_mtimespec.tv_sec, rootURL: URL(fileURLWithPath: rootPath))
        }
        try Task.checkCancellation()
        walk.report(rootPath)
        return node
    }

    /// Several folders under one virtual root named `name` (whose URL is `container`); missing folders are skipped.
    /// Each folder keeps its own URL, so `node(at:)` and removal work as for a single scan.
    public func scan(roots: [(url: URL, name: String)], name: String, container: URL,
                     progress: @escaping Progress) async throws -> SpaceNode {
        var children: [SpaceNode] = []
        for (url, label) in roots {
            let base = (children.reduce(0) { $0 + $1.size }, children.reduce(0) { $0 + $1.fileCount })
            guard let node = try? await scan(root: url, name: label, progress: { b, f, p in progress(base.0 + b, base.1 + f, p) })
            else { try Task.checkCancellation(); continue }
            children.append(node)
        }
        try Task.checkCancellation()
        return SpaceNode(name: name, size: children.reduce(0) { $0 + $1.size }, fileCount: children.reduce(0) { $0 + $1.fileCount },
                         isDirectory: true, children: children, rootURL: container)
    }

    /// iCloud Drive and File Provider folders (Google Drive, OneDrive, Dropbox, Box...).
    public static func cloudRoots(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [(url: URL, name: String)] {
        [(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), "iCloud Drive"),
         (home.appendingPathComponent("Library/CloudStorage"), "CloudStorage")]
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    static let volumeKeys: Set<URLResourceKey> = [.volumeURLKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                                  .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                  .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRootFileSystemKey]

    /// Mounted, browsable volumes for the volume picker (boot volume first).
    public static func volumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(volumeKeys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(volume(containing:)).sorted { $0.isBoot && !$1.isBoot }
    }

    /// The volume a scanned folder lives on, for the capacity gauge.
    public static func volume(containing url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: volumeKeys), let total = v.volumeTotalCapacity else { return nil }
        let available = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? available
        let volumeURL = v.volume ?? url
        return VolumeInfo(url: volumeURL, name: v.volumeLocalizedName ?? volumeURL.lastPathComponent, totalCapacity: Int64(total),
                          availableCapacity: available, purgeableCapacity: max(0, important - available),
                          isInternal: v.volumeIsInternal ?? false, isEjectable: v.volumeIsEjectable ?? false,
                          isBoot: v.volumeIsRootFileSystem ?? false)
    }
}

public struct VolumeInfo: Hashable, Sendable, Identifiable {
    public let url: URL
    public let name: String
    public let totalCapacity: Int64
    public let availableCapacity: Int64
    /// Space macOS can reclaim on demand (available for important usage − available).
    public let purgeableCapacity: Int64
    public let isInternal: Bool
    public let isEjectable: Bool
    public let isBoot: Bool
    public var id: URL { url }
    /// Denominator for scan progress.
    public var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity - purgeableCapacity) }
}

private struct DirResult: Sendable {
    var size: Int64 = 0
    var files = 0
    var children: [SpaceNode] = []
}

private final class Walk: Sendable {
    struct Counters { var bytes: Int64 = 0; var files = 0; var lastReport = ContinuousClock.now }

    let devices: Set<dev_t>
    let skipped: Set<String>
    let progress: SpaceScanner.Progress
    struct Inode: Hashable { let dev: dev_t; let ino: ino_t }
    let seenInodes = Mutex(Set<Inode>())
    let counters = Mutex(Counters())
    let width = max(2, ProcessInfo.processInfo.activeProcessorCount)

    init(devices: Set<dev_t>, skipped: Set<String>, progress: @escaping SpaceScanner.Progress) {
        self.devices = devices
        self.skipped = skipped
        self.progress = progress
    }

    func directory(path: String, depth: Int) async -> DirResult {
        let (files, dirs, local) = list(path: path)
        var result = DirResult(size: local, files: files.count, children: files)
        if depth >= SpaceScanner.parallelDepth || dirs.count < 2 {
            for (name, childPath, mtime) in dirs where !Task.isCancelled {
                result.add(node(name: name, mtime: mtime, walk: directorySync(path: childPath)))
            }
            return result
        }
        await withTaskGroup(of: SpaceNode.self) { group in
            var pending = dirs[...]
            func launch() {
                guard let (name, childPath, mtime) = pending.popFirst() else { return }
                group.addTask { [self] in node(name: name, mtime: mtime, walk: await directory(path: childPath, depth: depth + 1)) }
            }
            for _ in 0..<width { launch() }
            for await child in group {
                result.add(child)
                if !Task.isCancelled { launch() }
            }
        }
        return result
    }

    func directorySync(path: String) -> DirResult {
        let (files, dirs, local) = list(path: path)
        var result = DirResult(size: local, files: files.count, children: files)
        for (name, childPath, mtime) in dirs where !Task.isCancelled {
            result.add(node(name: name, mtime: mtime, walk: directorySync(path: childPath)))
        }
        return result
    }

    func node(name: String, mtime: Int, walk r: DirResult) -> SpaceNode {
        let isPackage = Self.isPackage(name)
        return SpaceNode(name: name, size: r.size, fileCount: r.files, isDirectory: true, isPackage: isPackage,
                         children: isPackage ? [] : r.children, mtime: mtime)
    }

    /// Reads one directory: file nodes, subdirectories to descend into, and bytes of files.
    func list(path: String) -> (files: [SpaceNode], dirs: [(String, String, Int)], bytes: Int64) {
        // Synchronous, so the thread policy covers exactly this listing and is restored before any suspension.
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) } }
        guard !Task.isCancelled, let dir = opendir(path) else { return ([], [], 0) }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var files: [SpaceNode] = []
        var dirs: [(String, String, Int)] = []
        var bytes: Int64 = 0
        var st = stat()
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if name == "." || name == ".." { continue }
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, devices.contains(st.st_dev) else { continue }
            let childPath = prefix + name
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if skipped.contains(childPath) || SpaceScanner.skippedSuffixes.contains(where: childPath.hasSuffix) { continue }
                if SpaceScanner.isDataless(st.st_flags) {
                    files.append(SpaceNode(name: name, size: 0, fileCount: 0, isDirectory: true, mtime: st.st_mtimespec.tv_sec))
                    continue
                }
                dirs.append((name, childPath, st.st_mtimespec.tv_sec))
                continue
            }
            var size = Int64(st.st_blocks) * 512
            if (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink > 1 {
                let key = Inode(dev: st.st_dev, ino: st.st_ino)
                if !seenInodes.withLock({ $0.insert(key).inserted }) { size = 0 }
            }
            bytes += size
            files.append(SpaceNode(name: name, size: size, fileCount: 1, isDirectory: false, mtime: st.st_mtimespec.tv_sec))
        }
        count(bytes: bytes, files: files.count, path: path)
        return (files, dirs, bytes)
    }

    func count(bytes: Int64, files: Int, path: String) {
        let now = ContinuousClock.now
        let snapshot: (Int64, Int)? = counters.withLock { c in
            c.bytes += bytes
            c.files += files
            guard now - c.lastReport >= .milliseconds(100) else { return nil }
            c.lastReport = now
            return (c.bytes, c.files)
        }
        if let (b, f) = snapshot { progress(b, f, path) }
    }

    func report(_ path: String) {
        let (b, f) = counters.withLock { ($0.bytes, $0.files) }
        progress(b, f, path)
    }

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return SpaceScanner.packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}

private extension DirResult {
    mutating func add(_ child: SpaceNode) {
        size += child.size
        files += child.fileCount
        children.append(child)
    }
}
