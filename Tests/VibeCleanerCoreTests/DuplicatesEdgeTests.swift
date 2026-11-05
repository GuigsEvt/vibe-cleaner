import Foundation
import Testing
@testable import VibeCleanerCore

/// Exact-duplicate detection on files written by the test. A wrong "identical" verdict lets the user
/// delete the only copy of a file, so every shortcut (size, head hash, inode) is checked here.
@Suite struct DuplicatesEdgeTests {
    let fm = FileManager.default
    let tmp: URL

    /// Real path (/private/var/...): enumerators return resolved paths, as `ClutterWalker` hands them to `findBundles`.
    init() throws {
        let made = fm.temporaryDirectory.appendingPathComponent("vc-dup-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        let real = try #require(realpath(made.path, nil))
        defer { free(real) }
        tmp = URL(fileURLWithPath: String(cString: real))
    }

    func entry(_ rel: String, _ data: Data, modified: Date? = nil) throws -> ClutterEntry {
        let url = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return ClutterEntry(url: url, size: Int64(data.count), allocated: Int64(data.count), modified: modified, accessed: nil, isImage: false)
    }

    func bytes(_ n: Int, seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed }) }

    @Test func sameHeadDifferentTailAreNotDuplicates() throws {
        var a = bytes(Duplicates.headLength + 10, seed: 1), b = a
        a[a.count - 1] = 0; b[b.count - 1] = 1
        let sets = try #require(Duplicates.find([try entry("a.bin", a), try entry("b.bin", b)], minSize: 1) { _ in })
        #expect(sets.isEmpty)
    }

    @Test func differenceInsideTheHeadOnFilesShorterThanIt() throws {
        var b = bytes(1_000, seed: 2)
        let a = b
        b[0] ^= 0xFF
        let sets = try #require(Duplicates.find([try entry("a.bin", a), try entry("b.bin", b)], minSize: 1) { _ in })
        #expect(sets.isEmpty)
    }

    @Test func exactlyHeadLengthAndMultiBlockFilesAreCompared() throws {
        let head = bytes(Duplicates.headLength, seed: 3)
        let big = bytes(Duplicates.blockLength * 2 + 7, seed: 4)
        var bigOther = big
        bigOther[Duplicates.blockLength + 3] ^= 1
        let entries = [try entry("h1", head), try entry("h2", head), try entry("b1", big), try entry("b2", big), try entry("b3", bigOther)]
        let sets = try #require(Duplicates.find(entries, minSize: 1) { _ in })
        let names = Set(sets.map { Set($0.map(\.url.lastPathComponent)) })
        #expect(names == [["h1", "h2"], ["b1", "b2"]])
    }

    @Test func hardLinksAndSymlinksAreNotCopies() throws {
        let data = bytes(5_000, seed: 5)
        let a = try entry("a.bin", data)
        let hard = tmp.appendingPathComponent("hard.bin")
        try fm.linkItem(at: a.url, to: hard)
        let soft = tmp.appendingPathComponent("soft.bin")
        try fm.createSymbolicLink(at: soft, withDestinationURL: a.url)
        let e = { (u: URL) in ClutterEntry(url: u, size: 5_000, allocated: 5_000, modified: nil, accessed: nil, isImage: false) }
        let sets = try #require(Duplicates.find([a, e(hard), e(soft)], minSize: 1) { _ in })
        // Hard link: same inode → one copy. Symlink: stat follows it, same inode → one copy too.
        #expect(sets.isEmpty)
    }

    @Test func filesGoneBeforeHashingAreDropped() throws {
        let data = bytes(2_000, seed: 6)
        let a = try entry("a.bin", data), b = try entry("b.bin", data), c = try entry("c.bin", data)
        try fm.removeItem(at: c.url)
        let sets = try #require(Duplicates.find([a, b, c], minSize: 1) { _ in })
        #expect(sets.map { Set($0.map(\.url.lastPathComponent)) } == [["a.bin", "b.bin"]])
    }

    @Test func unreadableFileIsNeverReportedAsACopy() throws {
        let data = bytes(2_000, seed: 7)
        let a = try entry("a.bin", data), b = try entry("b.bin", data)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: b.url.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.url.path) }
        let sets = try #require(Duplicates.find([a, b], minSize: 1) { _ in })
        #expect(sets.isEmpty)
        #expect(Duplicates.hash(b.url, limit: nil) == nil)
    }

    @Test func minSizeAndEmptyFiles() throws {
        let e1 = try entry("e1", Data()), e2 = try entry("e2", Data())
        #expect(try #require(Duplicates.find([e1, e2], minSize: 1) { _ in }).isEmpty)
        let small = bytes(10, seed: 8)
        #expect(try #require(Duplicates.find([try entry("s1", small), try entry("s2", small)], minSize: 11) { _ in }).isEmpty)
        #expect(Duplicates.hash(e1.url, limit: nil) == Duplicates.hash(e2.url, limit: 0))
    }

    @Test func progressEndsAtOneAndEmptyInputIsEmpty() throws {
        #expect(try #require(Duplicates.find([], minSize: 1) { _ in }).isEmpty)
        let d = bytes(100, seed: 9)
        var last = 0.0
        _ = Duplicates.find([try entry("p1", d), try entry("p2", d)], minSize: 1) { last = $0 }
        #expect(last == 1)
    }

    @Test func cancelledFindReturnsNil() async throws {
        let d = bytes(100, seed: 10)
        let entries = [try entry("c1", d), try entry("c2", d)]
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Duplicates.find(entries, minSize: 1) { _ in }
        }.value
        #expect(result == nil)
    }

    // MARK: Bundles

    @Test func bundlesDifferingByOneFileNameAreNotDuplicates() throws {
        for (b, name) in [("A.app", "x"), ("B.app", "y")] {
            let dir = tmp.appendingPathComponent("\(b)/Contents")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes(4_000, seed: 11).write(to: dir.appendingPathComponent(name))
        }
        let sets = try #require(Duplicates.findBundles([tmp.appendingPathComponent("A.app"), tmp.appendingPathComponent("B.app")], minSize: 1))
        #expect(sets.isEmpty)
    }

    @Test func bundlesDifferingBySymlinkTargetAreNotDuplicates() throws {
        for (b, target) in [("A.app", "one"), ("B.app", "two")] {
            let dir = tmp.appendingPathComponent(b)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes(4_000, seed: 12).write(to: dir.appendingPathComponent("f"))
            try fm.createSymbolicLink(atPath: dir.appendingPathComponent("l").path, withDestinationPath: target)
        }
        let sets = try #require(Duplicates.findBundles([tmp.appendingPathComponent("A.app"), tmp.appendingPathComponent("B.app")], minSize: 1))
        #expect(sets.isEmpty)
    }

    @Test func dsStoreDoesNotMakeBundlesDifferent() throws {
        for b in ["A.app", "B.app"] {
            let dir = tmp.appendingPathComponent(b)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes(4_000, seed: 13).write(to: dir.appendingPathComponent("f"))
        }
        try Data("finder".utf8).write(to: tmp.appendingPathComponent("A.app/.DS_Store"))
        let sets = try #require(Duplicates.findBundles([tmp.appendingPathComponent("A.app"), tmp.appendingPathComponent("B.app")], minSize: 1))
        #expect(sets.count == 1)
    }

    /// The enumerator returns resolved paths (/private/var/…) for a bundle given by its /var path: relative paths
    /// are cut from the resolved root.
    @Test func identicalBundlesGivenByTheirVarPath() throws {
        let unresolved = fm.temporaryDirectory.appendingPathComponent("vc-dup-var-\(UUID().uuidString)")
        #expect(unresolved.path.hasPrefix("/var/"))
        for b in ["A.app", "B.app"] {
            let dir = unresolved.appendingPathComponent(b)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes(4_000, seed: 14).write(to: dir.appendingPathComponent("f"))
        }
        let sets = try #require(Duplicates.findBundles([unresolved.appendingPathComponent("A.app"), unresolved.appendingPathComponent("B.app")], minSize: 1))
        #expect(sets.count == 1)
    }

    // MARK: Which copy is kept

    @Test func copyNumberEdges() {
        #expect(Duplicates.copyNumber("") == 0)
        #expect(Duplicates.copyNumber(".hidden copy") == 1)
        #expect(Duplicates.copyNumber("RAPPORT COPY 12.PDF") == 12)
        #expect(Duplicates.copyNumber("photo (0).jpg") == 0)
        #expect(Duplicates.copyNumber("Copie de rapport.pdf") == 1)
        // A year in parentheses is not a copy number (three digits at most).
        #expect(Duplicates.copyNumber("Film (2019).mkv") == 0)
    }

    @Test func orderedKeepsTheOriginalOverTheCopyAndOutsideDownloads() throws {
        let home = tmp
        let now = Date()
        let orig = ClutterEntry(url: home.appendingPathComponent("Documents/r.pdf"), size: 1, allocated: 1, modified: now, accessed: nil, isImage: false)
        let copy = ClutterEntry(url: home.appendingPathComponent("Documents/r copy.pdf"), size: 1, allocated: 1, modified: now, accessed: nil, isImage: false)
        let dl = ClutterEntry(url: home.appendingPathComponent("Downloads/r.pdf"), size: 1, allocated: 1, modified: now, accessed: nil, isImage: false)
        #expect(Duplicates.ordered([dl, copy, orig], home: home).map(\.url) == [orig.url, copy.url, dl.url])
        // Undated entries sort as the oldest (removed first among equals).
        let undated = ClutterEntry(url: home.appendingPathComponent("Documents/s.pdf"), size: 1, allocated: 1, modified: nil, accessed: nil, isImage: false)
        #expect(Duplicates.ordered([undated, orig], home: home).first?.url == orig.url)
    }
}
