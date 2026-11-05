import Foundation

/// Cloud cleanup, local only: large files of iCloud Drive and File Provider folders (Dropbox, Google Drive,
/// OneDrive, Box...) that are downloaded on this Mac. "Libérer" evicts the local copy; nothing is ever deleted from the cloud.
public struct CloudModule: ScanModule {
    public let id = "cloud"
    public let title = "Nettoyage cloud"
    public let subtitle = "Libère l'espace occupé par les gros fichiers iCloud Drive, Dropbox, Google Drive ou OneDrive téléchargés sur ce Mac. Ils restent disponibles dans le cloud."
    public let symbol = "icloud"
    public let actionTitle = "Libérer"
    public var minSize: Int64
    /// "Rarement utilisé": not opened for this long.
    public var rarelyUsedAge: TimeInterval = 30 * 86_400
    /// Reference date for ages; nil means now.
    public var now: Date?

    /// "Gros fichiers synchronisés localement": 50 Mo.
    public init() { minSize = 50 * 1024 * 1024 }
    public init(minSize: Int64) { self.minSize = minSize }

    static let evictKey = "evict"

    struct EvictError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Root: Sendable {
        let service: String
        let url: URL
    }

    /// iCloud Drive, Desktop and Documents when synced by iCloud, then each File Provider domain.
    static func roots(home: URL) -> [Root] {
        let fm = FileManager.default
        var out: [Root] = []
        let mobile = home.appendingPathComponent("Library/Mobile Documents")
        if fm.fileExists(atPath: mobile.path) { out.append(Root(service: "iCloud Drive", url: mobile)) }
        for name in ["Desktop", "Documents"] {
            let url = home.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true, !isCovered(url, by: mobile) {
                out.append(Root(service: "iCloud Drive", url: url))
            }
        }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let providers = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            out.append(Root(service: serviceName(url.lastPathComponent), url: url))
        }
        return out
    }

    /// Desktop or Documents that is already walked as part of iCloud Drive: a link into `Mobile Documents`, or the
    /// same folder (same inode) as iCloud Drive's own Desktop / Documents. Listed once, so nothing is counted twice.
    static func isCovered(_ url: URL, by mobile: URL) -> Bool {
        let path = Junk.realPath(url.path), container = Junk.realPath(mobile.path)
        if path == container || path.hasPrefix(container + "/") { return true }
        let twin = mobile.appendingPathComponent("com~apple~CloudDocs").appendingPathComponent(url.lastPathComponent)
        var a = stat(), b = stat()
        return stat(url.path, &a) == 0 && stat(twin.path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// "GoogleDrive-moi@gmail.com" → "Google Drive (moi@gmail.com)", "OneDrive-Personal" → "OneDrive (Personal)".
    static func serviceName(_ folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        // "-" or "-x" splits into nothing before the dash.
        guard let first = parts.first, !folder.hasPrefix("-") else { return folder }
        let known = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box", "pCloudDrive": "pCloud"]
        let name = known[first] ?? first
        guard parts.count > 1, parts[1] != parts[0] else { return name }
        return "\(name) (\(parts[1]))"
    }

    /// File Provider marks "Keep downloaded" items with `com.apple.fileprovider.pinned` (with a `#P`/`#PX` suffix).
    static func hasPinnedAttribute(_ url: URL) -> Bool {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return false }
        var buf = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buf, size, XATTR_NOFOLLOW) == size else { return false }
        return buf.split(separator: 0).contains { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("com.apple.fileprovider.pinned") }
    }

    /// "Toujours conservé" on the item or on a folder above it, up to `root`: pinning a folder pins everything below it.
    /// `cache` remembers folders already read.
    static func isPinned(_ url: URL, root: String, cache: inout [String: Bool]) -> Bool {
        if hasPinnedAttribute(url) { return true }
        var dir = (url.path as NSString).deletingLastPathComponent
        while dir.count >= root.count {
            let p = cache[dir] ?? hasPinnedAttribute(URL(fileURLWithPath: dir))
            cache[dir] = p
            if p { return true }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return false
    }

    /// Only a synced item whose local copy is current, fully uploaded and without conflict can be evicted without losing anything.
    static func isEvictable(_ v: URLResourceValues) -> Bool {
        isEvictable(ubiquitous: v.isUbiquitousItem, excludedFromSync: v.ubiquitousItemIsExcludedFromSync,
                    status: v.ubiquitousItemDownloadingStatus, uploaded: v.ubiquitousItemIsUploaded,
                    uploading: v.ubiquitousItemIsUploading, conflicts: v.ubiquitousItemHasUnresolvedConflicts)
    }

    static func isEvictable(ubiquitous: Bool?, excludedFromSync: Bool?, status: URLUbiquitousItemDownloadingStatus?,
                            uploaded: Bool?, uploading: Bool?, conflicts: Bool?) -> Bool {
        ubiquitous == true && excludedFromSync != true && (status == .current || status == .downloaded)
            && uploaded == true && uploading != true && conflicts != true
    }

    /// Not opened for longer than `age`; true when the date is unknown (the size threshold alone then decides).
    static func isRarelyUsed(_ lastUse: Date?, now: Date, age: TimeInterval) -> Bool {
        lastUse.map { now.timeIntervalSince($0) > age } ?? true
    }

    /// Cloud placeholder (`SF_DATALESS`): listing it would download its content.
    static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && SpaceScanner.isDataless(st.st_flags)
    }

    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentAccessDateKey, .contentModificationDateKey,
    ]
    /// Answered by fileproviderd over XPC, one round trip per file: only asked for large files.
    static let syncKeys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsExcludedFromSyncKey,
                                                .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemHasUnresolvedConflictsKey]

    public func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup] {
        collect(context: context, progress: progress)
    }

    func collect(context: ModuleContext, progress: ProgressHandler) -> [ResultGroup] {
        // Synchronous, so the thread policy covers the whole walk: a dataless file or folder is never materialized
        // (same policy as SpaceScanner), its listing or reading fails instead of downloading it.
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) } }
        let now = self.now ?? Date()
        // Enumerators report resolved paths (/private/var...), which `URL.resolvingSymlinksInPath` would strip.
        let roots = Self.roots(home: realpath(context.home.path, nil).map { p in defer { free(p) }; return URL(fileURLWithPath: String(cString: p)) } ?? context.home)
        var byService: [String: (items: [ResultItem], pinned: Int)] = [:]
        var order: [String] = []
        let keySet = Set(Self.keys)
        let excluded = context.exclusions.map { ($0 as NSString).expandingTildeInPath }
        func isExcluded(_ p: String) -> Bool { excluded.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
        for (i, root) in roots.enumerated() {
            if Task.isCancelled { return [] }
            progress(Double(i) / Double(max(roots.count, 1)), "Analyse de \(root.service)")
            if byService[root.service] == nil { order.append(root.service); byService[root.service] = ([], 0) }
            var pinnedDirs: [String: Bool] = [:]
            guard let e = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: Self.keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            else { continue }
            var seen = 0
            for case let url as URL in e {
                seen += 1
                if seen % 2000 == 0 {
                    if Task.isCancelled { return [] }
                    progress(Double(i) / Double(max(roots.count, 1)), url.deletingLastPathComponent().path)
                }
                autoreleasepool {
                    guard let v = try? url.resourceValues(forKeys: keySet) else { return }
                    if isExcluded(url.path) { if v.isDirectory == true { e.skipDescendants() }; return }
                    // A dataless folder is not listed (nor a dataless package measured): nothing of it is on this Mac.
                    if v.isDirectory == true, Self.isDataless(url) { e.skipDescendants(); return }
                    let isPackage = v.isPackage == true
                    if v.isDirectory == true && !isPackage { return }
                    guard v.isRegularFile == true || isPackage else { return }
                    func evictable() -> Bool { (try? url.resourceValues(forKeys: Self.syncKeys)).map(Self.isEvictable) ?? false }
                    // Measuring a package reads its whole tree: only once it is known to be downloaded and evictable.
                    if isPackage, !evictable() { return }
                    let size = isPackage ? FileSizer.size(of: url) : Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                    let used = [v.contentAccessDate, v.contentModificationDate].compactMap { $0 }.max()
                    guard size >= minSize, Self.isRarelyUsed(used, now: now, age: rarelyUsedAge), isPackage || evictable() else { return }
                    if Self.isPinned(url, root: root.url.path, cache: &pinnedDirs) { byService[root.service]!.pinned += 1; return }
                    let rel = String(url.deletingLastPathComponent().path.dropFirst(root.url.path.count))
                    byService[root.service]!.items.append(ResultItem(
                        name: url.lastPathComponent, detail: rel.isEmpty ? root.service : "\(root.service)\(rel)", url: url,
                        size: size, date: used, symbol: "icloud.and.arrow.down", action: .custom(Self.evictKey), autoSelect: false))
                }
            }
        }
        progress(1, "Terminé")
        let services = order.map { service in
            let s = byService[service]!
            var subtitle = "Gros fichiers téléchargés sur ce Mac et pas ouverts depuis plus de \(Int(rarelyUsedAge / 86_400)) jours. Libérer garde le fichier dans le cloud et supprime la copie locale."
            if s.pinned > 0 { subtitle += " \(s.pinned) fichier(s) « toujours conservé(s) » ignoré(s)." }
            return ResultGroup(id: "cloud.\(service)", title: service, subtitle: subtitle, symbol: "icloud",
                               items: s.items.sorted { $0.size > $1.size }, autoSelect: false)
        }
        return services + Self.filterGroups(services, now: now, rarelyUsedAge: rarelyUsedAge)
    }

    /// "Rarement utilisés" and the access / size / kind filters, over the items of every service.
    static func filterGroups(_ services: [ResultGroup], now: Date, rarelyUsedAge: TimeInterval) -> [ResultGroup] {
        let all = services.flatMap(\.items)
        guard !all.isEmpty else { return [] }
        let rarely = all.filter { isRarelyUsed($0.date, now: now, age: rarelyUsedAge) }
        return [
            ResultGroup(id: "cloud.rarely", title: "Gros fichiers rarement utilisés",
                        subtitle: "Fichiers synchronisés que vous n'avez pas ouverts depuis plus de \(Int(rarelyUsedAge / 86_400)) jours : libérez-les en priorité.",
                        symbol: "clock.arrow.circlepath", items: rarely.sorted { $0.size > $1.size }, autoSelect: false),
            FileFilters.group(all, by: .access, id: "cloud.byaccess", title: "Par date d'ouverture", now: now),
            FileFilters.group(all, by: .size, id: "cloud.bysize", title: "Par taille", now: now),
            FileFilters.group(all, by: .kind, id: "cloud.bykind", title: "Par type", now: now),
        ]
    }

    public func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport {
        let roots = Self.roots(home: URL(fileURLWithPath: Junk.realPath(context.home.path))).map(\.url.path)
        var pinnedDirs: [String: Bool] = [:]
        return ActionExecutor(remover: context.remover).run(items) { item, key in
            guard key == Self.evictKey, let url = item.url else { throw EvictError(message: "action non prise en charge") }
            try context.remover.check(url)
            // Up to the item's sync folder, or to the top when it is reached by another spelling.
            let root = roots.first { url.path.hasPrefix($0 + "/") } ?? "/"
            guard !Self.isPinned(url, root: root, cache: &pinnedDirs) else { throw EvictError(message: "\(url.lastPathComponent) est marqué « toujours conservé » sur ce Mac") }
            let v = try url.resourceValues(forKeys: Self.syncKeys)
            guard Self.isEvictable(v) else { throw EvictError(message: "\(url.lastPathComponent) n'est pas synchronisé, pas encore envoyé, en conflit ou déjà libéré") }
            try FileManager.default.evictUbiquitousItem(at: url)
        }
    }
}
