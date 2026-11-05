import Foundation
import UniformTypeIdentifiers

/// A regular file found under the home folder.
struct ClutterEntry: Sendable {
    let url: URL
    /// Logical length, used to compare contents.
    let size: Int64
    /// Space on disk, what removing the file frees.
    let allocated: Int64
    let modified: Date?
    let accessed: Date?
    let isImage: Bool
    var created: Date? = nil
    var kind: FileKind = .other
    /// A package (virtual machine, Final Cut library, sparse bundle…) counted as one file: totals of its contents.
    /// Listed with large files, never hashed as a single file.
    var isPackage = false
}

/// Walks the home folder once for every Fouillis category. Never reads file contents.
enum ClutterWalker {
    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .contentAccessDateKey, .contentTypeKey, .creationDateKey,
    ]
    /// Answered by fileproviderd over XPC: only asked for files that pass the size filter.
    static let cloudKeys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]

    /// Developer and system extensions never proposed, except sparse bundles
    /// and Photoshop documents: large user data that belongs in "Gros et vieux fichiers".
    static let ignoredExtensions: Set<String> = Set("""
    a so h pch c hpp h++ cpp c++ m swift java class idea py rb php css js json jar lib dylib dll ocx pth db rpl hds info def \
    properties proofingtool bup ar tmp hg vsd xsd xslt xsl entitlements xcconfig dsym cer crt applescript version \
    asset prefab unity html scss sh bash scala sc cs cake coffee cshtml csx ts vim vue plist yml yaml gradle md ruby gemfile gem \
    sql photoslibrary musiclibrary
    """.split(separator: " ").map(String.init))

    static let ignoredDirectoryNames: Set<String> = ["node_modules", "bower_components"]
    static let libraryExtensions: Set<String> = ["photoslibrary", "musiclibrary", "photolibrary", "aplibrary"]
    /// Packages counted as one large file even when no installed app declares their type as a package.
    static let packageExtensions: Set<String> = ["pvm", "fcpbundle", "sparsebundle", "vmwarevm", "utm"]

    /// Returns nil when cancelled. `bundles` receives every package met (apps, documents bundles), never descended into.
    static func walk(home: URL, exclusions: [String], minSize: Int64, bundles: ((URL) -> Void)? = nil,
                     progress: (Double, String) -> Void) -> [ClutterEntry]? {
        let fm = FileManager.default
        let h = home.path
        let skipped: Set<String> = ["\(h)/Library", "\(h)/Music/iTunes", "\(h)/Music/Music", "\(h)/.Trash"]
        let excluded = exclusions.map { clutterRealPath(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)).path }
        func isExcluded(_ p: String) -> Bool {
            skipped.contains(p) || excluded.contains { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        let keySet = Set(keys)
        var out: [ClutterEntry] = []

        func consider(_ url: URL, _ v: URLResourceValues) {
            guard v.isRegularFile == true else { return }
            let size = Int64(v.fileSize ?? 0)
            let allocated = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            guard max(size, allocated) >= minSize, !isExcluded(url.path) else { return }
            // A cloud placeholder would be downloaded just by reading it.
            if let c = try? url.resourceValues(forKeys: cloudKeys), c.isUbiquitousItem == true, c.ubiquitousItemDownloadingStatus != .current { return }
            out.append(ClutterEntry(url: url, size: size, allocated: allocated, modified: v.contentModificationDate,
                                    accessed: v.contentAccessDate, isImage: v.contentType?.conforms(to: .image) == true,
                                    created: v.creationDate, kind: FileKind(v.contentType)))
        }
        // Files inside a source repository belong to the project: removing a "duplicate" there can break it.
        func skipsDirectory(_ url: URL, _ v: URLResourceValues) -> Bool {
            if ignoredDirectoryNames.contains(url.lastPathComponent) || libraryExtensions.contains(url.pathExtension.lowercased())
                || isExcluded(url.path) || fm.fileExists(atPath: url.path + "/.git") { return true }
            let ext = url.pathExtension.lowercased()
            if v.isPackage == true || packageExtensions.contains(ext) {
                if v.isPackage == true { bundles?(url) }
                // Apps belong to the Applications module.
                if ext != "app", let p = package(url, v), max(p.size, p.allocated) >= minSize { out.append(p) }
                return true
            }
            return false
        }

        let tops = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var seen = 0
        for (i, top) in tops.enumerated() {
            if Task.isCancelled { return nil }
            progress(Double(i) / Double(max(tops.count, 1)), top.lastPathComponent)
            guard let v = try? top.resourceValues(forKeys: keySet) else { continue }
            if v.isDirectory != true { consider(top, v); continue }
            if skipsDirectory(top, v) { continue }
            guard let e = fm.enumerator(at: top, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
            else { continue }
            for case let url as URL in e {
                seen += 1
                if seen % 2000 == 0 {
                    if Task.isCancelled { return nil }
                    progress(Double(i) / Double(max(tops.count, 1)), url.deletingLastPathComponent().path)
                }
                autoreleasepool {
                    guard let cv = try? url.resourceValues(forKeys: keySet) else { return }
                    if cv.isDirectory == true {
                        if skipsDirectory(url, cv) { e.skipDescendants() }
                        return
                    }
                    consider(url, cv)
                }
            }
        }
        return out
    }
}

extension ClutterWalker {
    /// One entry for a whole package: summed logical and allocated sizes, latest modification and access inside
    /// (a virtual machine in use keeps its folder date). Nil when it holds a cloud placeholder (reading would download it).
    static func package(_ url: URL, _ v: URLResourceValues) -> ClutterEntry? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .contentModificationDateKey, .contentAccessDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return nil }
        var size: Int64 = 0, allocated: Int64 = 0
        var modified = v.contentModificationDate, accessed = v.contentAccessDate
        for case let f as URL in e {
            guard let fv = try? f.resourceValues(forKeys: Set(keys)), fv.isRegularFile == true else { continue }
            if fv.isUbiquitousItem == true && fv.ubiquitousItemDownloadingStatus != .current { return nil }
            size += Int64(fv.fileSize ?? 0)
            allocated += Int64(fv.totalFileAllocatedSize ?? fv.fileAllocatedSize ?? 0)
            modified = [modified, fv.contentModificationDate].compactMap { $0 }.max()
            accessed = [accessed, fv.contentAccessDate].compactMap { $0 }.max()
        }
        return ClutterEntry(url: url, size: size, allocated: allocated, modified: modified, accessed: accessed, isImage: false,
                            created: v.creationDate, kind: FileKind(v.contentType), isPackage: true)
    }
}

/// Runs `transform` over `input` with a bounded number of concurrent tasks, keeping input order.
func clutterConcurrentMap<T: Sendable, R: Sendable>(_ input: [T], width: Int = ProcessInfo.processInfo.activeProcessorCount,
                                                    onEach: @escaping @Sendable (Int) -> Void = { _ in },
                                                    _ transform: @escaping @Sendable (T) -> R?) async -> [R?] {
    var out = [R?](repeating: nil, count: input.count)
    await withTaskGroup(of: (Int, R?).self) { group in
        var next = 0, done = 0
        func add() {
            guard next < input.count else { return }
            let i = next, value = input[i]
            next += 1
            group.addTask { Task.isCancelled ? (i, nil) : (i, transform(value)) }
        }
        for _ in 0..<max(width, 1) { add() }
        while let (i, r) = await group.next() {
            out[i] = r
            done += 1
            onEach(done)
            add()
        }
    }
    return out
}

/// realpath(3): unlike `URL.resolvingSymlinksInPath`, keeps the /private prefix that enumerators report.
func clutterRealPath(_ url: URL) -> URL {
    guard let p = realpath(url.path, nil) else { return url }
    defer { free(p) }
    return URL(fileURLWithPath: String(cString: p))
}
