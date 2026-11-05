import CryptoKit
import Foundation

/// Exact duplicates: size, then hash of the first 64 KiB, then full SHA-256. Only colliding sizes are read.
public enum Duplicates {
    static let headLength = 64 * 1024
    static let blockLength = 1024 * 1024

    /// Sets of identical files (at least two, distinct inodes). Returns nil when cancelled.
    static func find(_ entries: [ClutterEntry], minSize: Int64, progress: (Double) -> Void) -> [[ClutterEntry]]? {
        let bySize = Dictionary(grouping: entries.filter { $0.size >= minSize }, by: \.size).values.filter { $0.count > 1 }
        let total = max(bySize.reduce(0) { $0 + $1.count }, 1)
        var done = 0
        var sets: [[ClutterEntry]] = []
        for sameSize in bySize {
            if Task.isCancelled { return nil }
            done += sameSize.count
            progress(Double(done) / Double(total))
            let distinct = uniqueInodes(sameSize)
            guard distinct.count > 1 else { continue }
            for head in regroup(distinct, by: { hash($0.url, limit: headLength) }) {
                let needsFull = head[0].size > Int64(headLength)
                for full in needsFull ? regroup(head, by: { hash($0.url, limit: nil) }) : [head] {
                    if Task.isCancelled { return nil }
                    sets.append(full)
                }
            }
        }
        return sets
    }

    /// Hard links share their data: removing one frees nothing, so keep one path per inode.
    static func uniqueInodes(_ entries: [ClutterEntry]) -> [ClutterEntry] {
        var seen = Set<String>()
        return entries.filter { e in
            var st = stat()
            guard stat(e.url.path, &st) == 0 else { return false }
            return seen.insert("\(st.st_dev):\(st.st_ino)").inserted
        }
    }

    static func regroup(_ entries: [ClutterEntry], by key: (ClutterEntry) -> String?) -> [[ClutterEntry]] {
        var buckets: [String: [ClutterEntry]] = [:]
        for e in entries { if let k = key(e) { buckets[k, default: []].append(e) } }
        return buckets.values.filter { $0.count > 1 }
    }

    /// A regular file with other hard links: removing this path frees nothing.
    static func isHardLinked(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink > 1
    }

    /// A cloud placeholder (iCloud, File Provider) whose data is not on this Mac: reading it would download it.
    static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Runs `body` with dataless-file materialization turned off for this thread (as `SpaceScanner` does):
    /// a read of a placeholder then fails instead of downloading it.
    static func withoutMaterializing<T>(_ body: () -> T) -> T {
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) } }
        return body()
    }

    /// SHA-256 of the first `limit` bytes, or of the whole file, read in 1 MiB blocks without polluting the disk cache.
    /// Never downloads a cloud placeholder.
    static func hash(_ url: URL, limit: Int?) -> String? {
        guard !isDataless(url) else { return nil }
        return withoutMaterializing { readHash(url, limit: limit) }
    }

    static func readHash(_ url: URL, limit: Int?) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        _ = fcntl(fh.fileDescriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            if Task.isCancelled { return nil }
            // Each read returns an autoreleased buffer: drain it per block or a large file stays in memory.
            // `read(upToCount:)` returns nil at end of file and throws on a real error.
            let read: Int? = autoreleasepool {
                do {
                    guard let chunk = try fh.read(upToCount: min(blockLength, remaining)) else { return 0 }
                    hasher.update(data: chunk)
                    return chunk.count
                } catch { return nil }
            }
            guard let read else { return nil }
            if read == 0 { break }
            remaining -= read
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Bundles

    struct BundleSummary {
        let entry: ClutterEntry
        /// Sorted (relative path, url) of regular files, and "relative path -> destination" of symlinks.
        let files: [(rel: String, url: URL)]
        let links: [String]
    }

    /// Bundles (apps, document packages) compared as one unit: same file count and total size first, then a digest of
    /// every relative path with its content hash. Returns nil when cancelled.
    static func findBundles(_ urls: [URL], minSize: Int64) -> [[ClutterEntry]]? {
        var summaries: [BundleSummary] = []
        for url in urls {
            if Task.isCancelled { return nil }
            if let s = summary(url), s.entry.size >= minSize { summaries.append(s) }
        }
        let candidates = Dictionary(grouping: summaries) { "\($0.entry.size):\($0.files.count):\($0.links.count)" }.values.filter { $0.count > 1 }
        var sets: [[ClutterEntry]] = []
        for group in candidates {
            var byDigest: [String: [ClutterEntry]] = [:]
            for s in group {
                if Task.isCancelled { return nil }
                if let d = digest(s) { byDigest[d, default: []].append(s.entry) }
            }
            sets += byDigest.values.filter { $0.count > 1 }
        }
        return sets
    }

    /// nil when the bundle holds a cloud item not downloaded on this Mac (hashing it would download it).
    static func summary(_ url: URL) -> BundleSummary? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        func notLocal(_ v: URLResourceValues?) -> Bool { v?.isUbiquitousItem == true && v?.ubiquitousItemDownloadingStatus != .current }
        guard !isDataless(url), !notLocal(try? url.resourceValues(forKeys: Set(keys))),
              let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return nil }
        // The enumerator returns resolved paths (/private/var/...): relative paths are cut from the resolved root.
        let resolved = clutterRealPath(url).path
        func relative(_ p: String) -> String {
            for base in [resolved, url.path] where p.hasPrefix(base + "/") { return String(p.dropFirst(base.count)) }
            return p
        }
        var size: Int64 = 0, allocated: Int64 = 0
        var files: [(rel: String, url: URL)] = [], links: [String] = []
        for case let f as URL in e where f.lastPathComponent != ".DS_Store" {
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            if notLocal(v) || isDataless(f) { return nil }
            let rel = relative(f.path)
            if v.isSymbolicLink == true {
                links.append(rel + " -> " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: f.path)) ?? ""))
            } else if v.isRegularFile == true {
                size += Int64(v.fileSize ?? 0)
                allocated += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                files.append((rel, f))
            }
        }
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey, .creationDateKey, .contentTypeKey])
        let entry = ClutterEntry(url: url, size: size, allocated: allocated, modified: v?.contentModificationDate,
                                 accessed: v?.contentAccessDate, isImage: false, created: v?.creationDate, kind: FileKind(v?.contentType))
        return BundleSummary(entry: entry, files: files.sorted { $0.rel < $1.rel }, links: links.sorted())
    }

    static func digest(_ s: BundleSummary) -> String? {
        var hasher = SHA256()
        for f in s.files {
            guard let h = hash(f.url, limit: nil) else { return nil }
            hasher.update(data: Data("\(f.rel)\u{0}\(h)\n".utf8))
        }
        for l in s.links { hasher.update(data: Data("\(l)\n".utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Smart selection

    /// Orders a duplicate set from best copy to keep to first to remove. Two rules come first: a hard-linked copy is kept
    /// (removing it frees nothing), then a copy of the home folder over one of an external disk (unplugging the disk would
    /// otherwise take the file away). Then 7 ordered rules: in Downloads, greater copy number, outside Photos,
    /// older modification, deeper path, shorter name, path order.
    static func ordered(_ set: [ClutterEntry], home: URL) -> [ClutterEntry] {
        let downloads = home.path + "/Downloads/"
        let linked = Set(set.filter { isHardLinked($0.url) }.map(\.url))
        func key(_ e: ClutterEntry) -> (Bool, Int, Bool, Date, Int, Int, String) {
            let p = e.url.path
            return (p.hasPrefix(downloads), copyNumber(e.url.lastPathComponent), !p.contains(".photoslibrary/"),
                    e.modified ?? .distantPast, e.url.pathComponents.count, e.url.lastPathComponent.count, p)
        }
        return set.sorted { a, b in
            let la = linked.contains(a.url), lb = linked.contains(b.url)
            if la != lb { return la }
            let ha = a.url.path.hasPrefix(home.path + "/"), hb = b.url.path.hasPrefix(home.path + "/")
            if ha != hb { return ha }
            let ka = key(a), kb = key(b)
            if ka.0 != kb.0 { return !ka.0 }          // keep outside Downloads
            if ka.1 != kb.1 { return ka.1 < kb.1 }    // keep lower copy number
            if ka.2 != kb.2 { return !ka.2 }          // keep the Photos one
            if ka.3 != kb.3 { return ka.3 > kb.3 }    // keep newer
            if ka.4 != kb.4 { return ka.4 < kb.4 }    // keep shallower
            if ka.5 != kb.5 { return ka.5 > kb.5 }    // keep longer name
            return ka.6 < kb.6
        }
    }

    nonisolated(unsafe) static let copySuffix = /(?i)[\s_-]\(?(?:copy|copie|copia|cópia|kopie|kopia|kopi|kopija|kopio|kopya|salin)\)?(?:\s*(\d+))?$/
    nonisolated(unsafe) static let copyPrefix = /(?i)^(?:copy of|copie de|cópia de|copia de|salinan)\s/
    /// "x (2)" is a copy, "Rapport (2024)" a year: three digits at most.
    nonisolated(unsafe) static let numberSuffix = /\s\((\d{1,3})\)$/

    /// 0 for an original, 1 for "x copy", "x - copie", "Copy of x", n for "x copy n" or "x (n)".
    static func copyNumber(_ fileName: String) -> Int {
        let stem = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        if let m = stem.firstMatch(of: numberSuffix) { return Int(m.1) ?? 1 }
        if let m = stem.firstMatch(of: copySuffix) { return m.1.flatMap { Int($0) } ?? 1 }
        if stem.firstMatch(of: copyPrefix) != nil { return 1 }
        return 0
    }
}
