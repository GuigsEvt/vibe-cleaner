import CoreServices
import Foundation

/// Fouillis: duplicates, similar images, large and old files, and forgotten downloads in the home folder.
/// Everything selected goes to the Trash.
public struct ClutterModule: ScanModule {
    public struct Options: Sendable {
        public var duplicateMinSize: Int64 = 100 * 1024
        public var imageMinSize: Int64 = 100 * 1024
        public var largeMinSize: Int64 = 50 * 1024 * 1024
        public var oldAge: TimeInterval = 365 * 86_400
        public var downloadsAge: TimeInterval = 30 * 86_400
        /// "Doublons récents" tile.
        public var freshAge: TimeInterval = 90 * 86_400
        public var similarityThreshold = ImageHash.threshold
        /// "Images similaires récentes" tile.
        public var similarFreshAge: TimeInterval = 30 * 86_400
        /// "Grandes images similaires" tile: a set with an image at least this big.
        public var similarLargeSize: Int64 = 5_000_000
        /// Mounted volumes walked in addition to the home folder (see `mountedExternalVolumes()`). Off by default:
        /// reading a removable volume can make macOS ask for permission.
        public var externalVolumes: [URL] = []
        /// Vibe Check card: only duplicates involving Downloads (copies outside Downloads never preselected) and large files.
        public var vibeCheck = false
        /// Reference date for ages; nil means now.
        public var now: Date?

        public init() {}

        public static var vibeCheck: Options {
            var o = Options()
            o.vibeCheck = true
            return o
        }
    }

    public let id = "clutter"
    public let title = "Fouillis"
    public let subtitle = "Trouve les doublons, les images similaires, les gros fichiers oubliés et les vieux téléchargements de votre dossier personnel."
    public let symbol = "square.stack.3d.up"
    public let actionTitle = "Supprimer"
    public var options: Options

    /// Names of the installed apps (bundle names without `.app`), asked only when Downloads holds an old installer. Test seam.
    var installedAppNames: @Sendable (URL) -> [String] = { home in
        AppInventory.appURLs(in: ["/Applications", "/System/Applications"].map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")])
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    public init() { options = Options() }
    public init(options: Options) { self.options = options }

    /// Local, writable, browsable volumes other than the startup disk (external disks, USB keys). Disk images are read-only
    /// or hidden and network shares are not local: none of them is listed.
    public static func mountedExternalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return url.path.hasPrefix("/Volumes/") && v?.volumeIsRootFileSystem != true && v?.volumeIsLocal == true
                && v?.volumeIsBrowsable == true && v?.volumeIsReadOnly != true
        }
    }

    public func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup] {
        let o = options
        let now = o.now ?? Date()
        // Enumerators return resolved paths (/private/var...), so every prefix test works on the resolved home.
        let home = clutterRealPath(context.home)
        progress(0, "Énumération du dossier personnel")
        let minSize = min(o.duplicateMinSize, o.imageMinSize, o.largeMinSize)
        var bundles: [URL] = []
        var entries: [ClutterEntry] = []
        let roots = [home] + o.externalVolumes.map(clutterRealPath)
        for (i, root) in roots.enumerated() {
            let base = 0.45 * Double(i) / Double(roots.count), span = 0.45 / Double(roots.count)
            guard let found = ClutterWalker.walk(home: root, exclusions: context.exclusions, minSize: minSize,
                                                 bundles: { bundles.append($0) },
                                                 progress: { f, step in progress(base + span * f, step) })
            else { return [] }
            entries += found
        }
        let candidates = entries.filter { !ClutterWalker.ignoredExtensions.contains($0.url.pathExtension.lowercased()) }

        progress(0.45, "Recherche des doublons")
        guard var sets = Duplicates.find(candidates.filter { !$0.isPackage }, minSize: o.duplicateMinSize, progress: { progress(0.45 + 0.2 * $0, "Comparaison des doublons") }),
              let bundleSets = Duplicates.findBundles(bundles, minSize: o.duplicateMinSize)
        else { return [] }
        sets += bundleSets
        let ordered = sets.map { Duplicates.ordered($0, home: home) }
        let copySets = CopySets(ordered)
        let downloads = home.path + "/Downloads/"

        if o.vibeCheck {
            progress(0.9, "Gros fichiers")
            let inDownloads = ordered.filter { $0.contains { $0.url.path.hasPrefix(downloads) } }
            let duplicates = duplicatesGroup(inDownloads) { e, i in i > 0 && e.url.path.hasPrefix(downloads) }
            let large = largeGroup(candidates.filter { $0.allocated >= o.largeMinSize }, now: now, oldAge: o.oldAge)
            progress(1, "Terminé")
            return [duplicates, large].map { copySets.attach($0.pruned()) }
        }

        // One card per kind of clutter; its former variants (recent, Desktop, by type…) are filters of the review.
        // Nothing is preselected: files are picked one by one.
        var duplicates = duplicatesGroup(ordered) { _, i in i > 0 }
        duplicates = Self.tagDuplicates(duplicates, sets: ordered, home: home, now: now, freshAge: o.freshAge)

        progress(0.65, "Recherche des images similaires")
        // Extra copies of an exact duplicate would only repeat the duplicates category.
        let extraCopies = Set(duplicates.allItems.filter(\.autoSelect).map(\.id))
        let images = candidates.filter { $0.isImage && max($0.size, $0.allocated) >= o.imageMinSize && !extraCopies.contains($0.url.path) }
        var similar = await similarGroup(images, threshold: o.similarityThreshold, progress: progress)
        if Task.isCancelled { return [] }
        similar = Self.tagSimilar(similar, entries: images, now: now, freshAge: o.similarFreshAge, largeSize: o.similarLargeSize)

        progress(0.95, "Gros fichiers et téléchargements")
        var large = largeGroup(candidates.filter { $0.allocated >= o.largeMinSize }, now: now, oldAge: o.oldAge)
        large.facetKeys = [Self.openedTag, Self.sizeTag, Self.kindTag]
        // The copy a duplicate set keeps is never preselected, not even as an old installer in Downloads.
        var dl = downloadsGroup(home: home, context: context, now: now, age: o.downloadsAge, keep: Set(ordered.map { $0[0].url.path }))
        dl = Self.tagDownloads(dl)
        progress(1, "Terminé")
        // The smart choice stays in `defaultSelection`; the app starts these cards empty (`ResultQueries.oneByOneGroupIDs`).
        return [duplicates, similar, large, dl].map { copySets.attach($0.pruned()) }
    }

    public func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport {
        // The same file can show up in several categories.
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        // A duplicate copy goes only if another, unselected copy of its set is still there with the same size.
        let selected = Set(unique.compactMap { $0.url?.path })
        // Any occurrence of the file may carry its set (a large file listed apart from its duplicates card).
        var sets: [String: [FileCopy]] = [:]
        for item in items where !item.copySet.isEmpty { sets[item.id] = item.copySet }
        var skipped: [(id: String, reason: String)] = []
        let runnable = unique.filter { item in
            guard let url = item.url, let members = sets[item.id] else { return true }
            let survivor = members.contains { !selected.contains($0.path) && CopySets.isUnchanged($0) }
            if !survivor {
                skipped.append((item.id, "Aucun autre exemplaire de « \(url.lastPathComponent) » n'est conservé à l'identique : copie laissée en place."))
            }
            return survivor
        }
        var report = ActionExecutor(remover: context.remover).run(runnable)
        report.failures = skipped + report.failures
        return report
    }

    // MARK: Filters

    /// Filter labels of the review (`ResultGroup.tags`).
    static let whenTag = "Quand", placeTag = "Où", kindTag = "Type", sizeTag = "Taille", openedTag = "Ouverture", sourceTag = "Source"

    /// Each duplicate set says when it appeared, where its copies are and what it is.
    static func tagDuplicates(_ group: ResultGroup, sets: [[ClutterEntry]], home: URL, now: Date, freshAge: TimeInterval) -> ResultGroup {
        let byFirst = Dictionary(sets.map { ($0[0].url.path, $0) }, uniquingKeysWith: { a, _ in a })
        var g = group
        g.groups = group.groups.map { sub in
            var sub = sub
            sub.keepsFirst = true
            guard let set = sub.items.first?.url.flatMap({ byFirst[$0.path] }) else { return sub }
            let fresh = set.contains { e in (e.created ?? e.modified).map { now.timeIntervalSince($0) < freshAge } ?? false }
            func under(_ dir: String) -> Bool { set.contains { $0.url.path.hasPrefix(home.path + "/\(dir)/") } }
            let place = under("Desktop") ? "Bureau" : under("Documents") ? "Documents" : under("Downloads") ? "Téléchargements" : "Ailleurs"
            sub.tags = [whenTag: fresh ? "Récents" : "Plus anciens", placeTag: place, kindTag: set[0].kind.title]
            return sub
        }
        g.facetKeys = [whenTag, placeTag, kindTag]
        return g
    }

    /// Each series of similar images says whether it is recent and whether it holds a large picture.
    static func tagSimilar(_ group: ResultGroup, entries: [ClutterEntry], now: Date, freshAge: TimeInterval, largeSize: Int64) -> ResultGroup {
        let byPath = Dictionary(entries.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        var g = group
        g.groups = group.groups.map { sub in
            var sub = sub
            sub.keepsFirst = true
            let members = sub.items.compactMap { $0.url.flatMap { byPath[$0.path] } }
            let fresh = members.contains { e in (e.created ?? e.modified).map { now.timeIntervalSince($0) < freshAge } ?? false }
            let large = members.contains { max($0.size, $0.allocated) >= largeSize }
            sub.tags = [whenTag: fresh ? "Récentes" : "Plus anciennes", sizeTag: large ? "Grandes" : "Petites"]
            return sub
        }
        g.facetKeys = [whenTag, sizeTag]
        return g
    }

    /// Each download says which app or site it came from.
    static func tagDownloads(_ group: ResultGroup) -> ResultGroup {
        var g = group
        g.groups = group.groups.map { sub in
            var sub = sub
            sub.items = sub.items.map { item in
                var item = item
                if let url = item.url { item.tags = [sourceTag: DownloadOrigin.source(url).app] }
                return item
            }
            return sub
        }
        g.facetKeys = [sourceTag]
        return g
    }

    // MARK: Groups

    static func item(_ e: ClutterEntry, detail: String? = nil, date: Date? = nil, autoSelect: Bool) -> ResultItem {
        ResultItem(name: e.url.lastPathComponent, detail: detail ?? e.url.deletingLastPathComponent().path, url: e.url,
                   size: e.allocated, date: date ?? e.modified, action: .delete(e.url, mode: .trash, admin: false), autoSelect: autoSelect)
    }

    /// One duplicate set, best copy to keep first. `select` decides which copies are preselected; a hard-linked copy
    /// never is, and does not count as recoverable (its data stays on disk through the other link).
    static func setGroup(_ ordered: [ClutterEntry], id: String, select: (ClutterEntry, Int) -> Bool) -> ResultGroup {
        let linked = Set(ordered.filter { Duplicates.isHardLinked($0.url) }.map(\.url))
        let items = ordered.enumerated().map { i, e in
            let note = i == 0 ? "Conservé · " : (linked.contains(e.url) ? "Lien physique, ne libère rien · " : "")
            return Self.item(e, detail: note + e.url.deletingLastPathComponent().path, autoSelect: select(e, i) && !linked.contains(e.url))
        }
        let wasted = items.dropFirst().filter { !($0.url.map(linked.contains) ?? false) }.reduce(0) { $0 + $1.size }
        return ResultGroup(id: "\(id).\(ordered[0].url.path)", title: ordered[0].url.lastPathComponent,
                           subtitle: "\(ordered.count) exemplaires · \(FileSizer.format(wasted)) récupérables",
                           symbol: "doc.on.doc", items: items)
    }

    func duplicatesGroup(_ sets: [[ClutterEntry]], select: (ClutterEntry, Int) -> Bool) -> ResultGroup {
        let subgroups = sets.map { Self.setGroup($0, id: "clutter.dup", select: select) }.sorted { $0.totalSize > $1.totalSize }
        return ResultGroup(id: "clutter.duplicates", title: "Doublons",
                           subtitle: "Copies identiques d'un même fichier rangées à plusieurs endroits. Un exemplaire est toujours conservé.",
                           symbol: "doc.on.doc", groups: subgroups)
    }

    func similarGroup(_ images: [ClutterEntry], threshold: Int, progress: @escaping ProgressHandler) async -> ResultGroup {
        let total = Double(max(images.count, 1))
        let urls = images.map(\.url)
        let hashed = await clutterConcurrentMap(urls, onEach: { n in
            if n % 50 == 0 { progress(0.65 + 0.25 * Double(n) / total, "Analyse des images (\(n)/\(Int(total)))") }
        }) { url in autoreleasepool { ImageHash(url: url) } }
        let valid = zip(images, hashed).compactMap { e, h in h.map { (e, $0) } }
        let clusters = ImageHash.clusters(valid.map(\.1), threshold: threshold)
        let clustered = clusters.flatMap { $0 }
        let measured = await clutterConcurrentMap(clustered.map { valid[$0].0.url }) { url in autoreleasepool { ImageQuality(url: url) } }
        let quality = Dictionary(uniqueKeysWithValues: zip(clustered, measured))
        let subgroups = clusters.map { members -> ResultGroup in
            // Best to keep first, then by resolution.
            var sorted = members.sorted { valid[$0].1.width * valid[$0].1.height > valid[$1].1.width * valid[$1].1.height }
            let q = sorted.compactMap { quality[$0] ?? nil }
            var best: Int?
            if q.count == sorted.count {
                let b = ImageQuality.best(q, pixels: sorted.map { valid[$0].1.width * valid[$0].1.height })
                best = sorted[b]
                sorted.insert(sorted.remove(at: b), at: 0)
            }
            let group = sorted.compactMap { quality[$0] ?? nil }
            let items = sorted.map { i -> ResultItem in
                let (e, h) = valid[i]
                let flaws = (quality[i] ?? nil).map { $0.flaws(in: group) } ?? []
                let notes = (i == best ? ["Meilleure à garder"] : []) + flaws + ["\(h.width)×\(h.height)", e.url.deletingLastPathComponent().path]
                return Self.item(e, detail: notes.joined(separator: " · "), autoSelect: false)
            }
            let first = valid[sorted[0]].0.url
            return ResultGroup(id: "clutter.sim.\(first.path)", title: first.lastPathComponent,
                               subtitle: "\(items.count) images presque identiques", symbol: "photo.on.rectangle",
                               items: items, autoSelect: false)
        }.sorted { $0.totalSize > $1.totalSize }
        return ResultGroup(id: "clutter.similar", title: "Images similaires",
                           subtitle: "Prises de vue presque identiques : gardez la meilleure, supprimez les autres.",
                           symbol: "photo.on.rectangle", groups: subgroups, autoSelect: false)
    }

    enum SizeBucket: Int, CaseIterable {
        case huge, big, medium
        var title: String {
            switch self { case .huge: "Plus de 5 Go"; case .big: "1 à 5 Go"; case .medium: "50 Mo à 1 Go" }
        }
        init(_ bytes: Int64) {
            self = bytes > 5_000_000_000 ? .huge : (bytes >= 1_000_000_000 ? .big : .medium)
        }
    }

    /// Most recent known use: Spotlight's last-used date, the access date, then the modification date.
    static func lastUsed(_ e: ClutterEntry) -> Date? {
        var spotlight: Date?
        if let md = MDItemCreateWithURL(kCFAllocatorDefault, e.url as CFURL) {
            spotlight = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
        }
        return [spotlight, e.accessed].compactMap { $0 }.max() ?? e.modified
    }

    func largeGroup(_ entries: [ClutterEntry], now: Date, oldAge: TimeInterval) -> ResultGroup {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        var buckets: [String: (order: Int, title: String, items: [ResultItem])] = [:]
        for e in entries {
            let used = Self.lastUsed(e)
            let old = used.map { now.timeIntervalSince($0) > oldAge } ?? true
            let bucket = SizeBucket(e.allocated)
            let key = "\(old ? "old" : "recent").\(bucket.rawValue)"
            let title = bucket.title + (old ? " · non ouverts depuis plus d'un an" : " · ouverts récemment")
            let detail = "Dernière ouverture : \(used.map(formatter.string(from:)) ?? "inconnue") · \(e.url.deletingLastPathComponent().path)"
            var item = Self.item(e, detail: detail, date: used, autoSelect: false)
            item.tags = [Self.kindTag: e.kind.title]
            buckets[key, default: ((old ? 0 : 10) + bucket.rawValue, title, [])].items.append(item)
        }
        let subgroups = buckets.sorted { $0.value.order < $1.value.order }.map { key, b in
            var g = ResultGroup(id: "clutter.large.\(key)", title: b.title, symbol: "externaldrive",
                                items: b.items.sorted { $0.size > $1.size }, autoSelect: false)
            let bucket = SizeBucket(rawValue: b.order % 10) ?? .medium
            g.tags = [Self.openedTag: key.hasPrefix("old") ? "Pas ouverts depuis un an" : "Ouverts récemment", Self.sizeTag: bucket.title]
            return g
        }
        return ResultGroup(id: "clutter.large", title: "Gros et vieux fichiers",
                           subtitle: "Vos fichiers les plus volumineux, souvent oubliés depuis longtemps.",
                           symbol: "externaldrive", groups: subgroups, autoSelect: false)
    }

    // MARK: Downloads

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]

    /// Encrypted disk image: "encrcdsa" header (v2) or "cdsaencr" trailer (v1). It holds data, not an installer.
    static func isEncryptedDiskImage(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dmg", let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let magics = [Data("encrcdsa".utf8), Data("cdsaencr".utf8)]
        if let head = try? fh.read(upToCount: 8), magics.contains(head) { return true }
        guard let end = try? fh.seekToEnd(), end >= 8, (try? fh.seek(toOffset: end - 8)) != nil,
              let tail = try? fh.read(upToCount: 8) else { return false }
        return magics.contains(tail)
    }

    /// An old .dmg/.pkg is preselected as "Installeur déjà utilisé" only when it installs an app found in the
    /// inventory (same name rule as the uninstaller), is not an encrypted image and is not a kept copy (`keep`).
    func downloadsGroup(home: URL, context: ModuleContext, now: Date, age: TimeInterval, keep: Set<String> = []) -> ResultGroup {
        let dir = home.appendingPathComponent("Downloads")
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var old: [ResultItem] = [], veryOld: [ResultItem] = [], recent: [ResultItem] = []
        var names: [String]?
        for url in urls where !context.isExcluded(url) {
            if Task.isCancelled { break }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let added = v?.addedToDirectoryDate ?? v?.creationDate ?? v?.contentModificationDate
            let elapsed = added.map { now.timeIntervalSince($0) } ?? 0
            let stale = elapsed > age
            var item = ResultItem(name: url.lastPathComponent, detail: dir.path, url: url, size: FileSizer.size(of: url), date: added,
                                  symbol: Self.installerExtensions.contains(url.pathExtension.lowercased()) ? "shippingbox" : nil,
                                  action: .delete(url, mode: .trash, admin: false), autoSelect: false)
            if stale && Self.installerExtensions.contains(url.pathExtension.lowercased()) && !keep.contains(url.path)
                && !Self.isEncryptedDiskImage(url) {
                let installed = names ?? installedAppNames(home)
                names = installed
                let stem = url.deletingPathExtension().lastPathComponent
                if installed.contains(where: { AppFootprint.isInstaller(stem, of: $0, installedNames: installed) }) {
                    item.autoSelect = true
                    item.detail = "Installeur déjà utilisé · \(dir.path)"
                }
            }
            if !stale { recent.append(item) } else if elapsed > 365 * 86_400 { veryOld.append(item) } else { old.append(item) }
        }
        func group(_ id: String, _ title: String, _ items: [ResultItem], auto: Bool) -> ResultGroup {
            ResultGroup(id: "clutter.dl.\(id)", title: title, symbol: "arrow.down.circle",
                        items: items.sorted { $0.size > $1.size }, autoSelect: auto)
        }
        return ResultGroup(id: "clutter.downloads", title: "Téléchargements",
                           subtitle: "Fichiers téléchargés souvent utilisés une seule fois. Filtrez par app ou site d'origine.",
                           symbol: "arrow.down.circle",
                           groups: [group("year", "Plus d'un an", veryOld, auto: true),
                                    group("month", "Plus de 30 jours", old, auto: true),
                                    group("recent", "Moins de 30 jours", recent, auto: false)])
    }
}

/// Duplicate sets of one scan, by member path. `attach` gives each item of that scan whose file belongs to a set
/// its `copySet`: `execute` only receives the selected items and checks that another copy survives before trashing one.
struct CopySets {
    private var byPath: [String: [FileCopy]] = [:]

    init(_ sets: [[ClutterEntry]]) {
        for set in sets {
            let members = set.map { FileCopy(path: $0.url.path, size: $0.size, modified: $0.modified) }
            for m in members { byPath[m.path] = members }
        }
    }

    func attach(_ group: ResultGroup) -> ResultGroup {
        var g = group
        g.items = g.items.map { item in
            var item = item
            if let path = item.url?.path, let set = byPath[path] { item.copySet = set }
            return item
        }
        g.groups = g.groups.map(attach)
        return g
    }

    /// Still the copy the scan compared: same length and, for a regular file, same modification date (a rewrite of
    /// the same length). A bundle's date is its newest file's, so only its summed contents are compared.
    static func isUnchanged(_ copy: FileCopy) -> Bool {
        let url = URL(fileURLWithPath: copy.path)
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        else { return false }
        if v.isRegularFile == true {
            return Int64(v.fileSize ?? 0) == copy.size && (copy.modified == nil || v.contentModificationDate == copy.modified)
        }
        return v.isDirectory == true && Duplicates.summary(url)?.entry.size == copy.size
    }
}
