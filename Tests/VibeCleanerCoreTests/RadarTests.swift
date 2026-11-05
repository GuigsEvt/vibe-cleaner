import Darwin
import Foundation
import Testing
@testable import VibeCleanerCore

@Suite final class RadarTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("radar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ rel: String, kb: Int) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<kb * 1024).map { _ in UInt8.random(in: 1...255) }).write(to: url)
        return url
    }

    func allocated(_ url: URL) -> Int64 {
        var st = stat()
        lstat(url.path, &st)
        return Int64(st.st_blocks) * 512
    }

    func scan(_ url: URL? = nil) async throws -> SpaceNode {
        try await SpaceScanner().scan(root: url ?? root) { _, _, _ in }
    }

    @Test func aggregatesSizesAndSortsChildren() async throws {
        let f1 = try file("a/f1", kb: 8), f2 = try file("a/sub/f2", kb: 40), f3 = try file("b/f3", kb: 4)
        let f4 = try file("top", kb: 12)
        let tree = try await scan()
        let a = try #require(tree.children.first { $0.name == "a" })
        #expect(a.size == allocated(f1) + allocated(f2))
        #expect(a.fileCount == 2)
        #expect(tree.size == [f1, f2, f3, f4].map(allocated).reduce(0, +))
        #expect(tree.fileCount == 4)
        #expect(tree.children.map(\.name) == ["a", "top", "b"])
        #expect(a.children.first?.name == "sub")
        #expect(a.children.first?.parent === a)
        #expect(tree.node(at: f2.standardizedFileURL.path)?.size == allocated(f2))
    }

    @Test func hardLinkCountedOnce() async throws {
        let f = try file("x/big", kb: 32)
        try FileManager.default.linkItem(at: f, to: root.appendingPathComponent("y-link"))
        let tree = try await scan()
        #expect(tree.size == allocated(f))
    }

    @Test func symlinkNotFollowed() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("radar-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data(count: 0).write(to: outside.appendingPathComponent("x"))
        try Data((0..<64 * 1024).map { _ in UInt8.random(in: 1...255) }).write(to: outside.appendingPathComponent("big"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let f = try file("real", kb: 4)
        let tree = try await scan()
        let link = try #require(tree.children.first { $0.name == "link" })
        #expect(!link.isDirectory && link.children.isEmpty)
        #expect(tree.size < 64 * 1024)
        #expect(tree.size >= allocated(f))
    }

    @Test func packageIsALeaf() async throws {
        let f = try file("Foo.app/Contents/MacOS/foo", kb: 16)
        let tree = try await scan()
        let app = try #require(tree.children.first)
        #expect(app.isPackage && app.children.isEmpty && app.fileCount == 1)
        #expect(app.size == allocated(f))
    }

    @Test func cancellationThrows() async throws {
        try file("a/b", kb: 4)
        let scanRoot = root
        await #expect(throws: CancellationError.self) {
            try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await SpaceScanner().scan(root: scanRoot) { _, _, _ in }
            }.value
        }
    }

    @Test func reportsProgress() async throws {
        try file("a", kb: 4)
        let calls = Counter()
        _ = try await SpaceScanner().scan(root: root) { _, files, _ in calls.set(files) }
        #expect(calls.value == 1)
    }

    @Test func bubblesFoldSmallerItems() async throws {
        for i in 1...10 { try file("big\(i)", kb: 40 + i) }
        for i in 1...20 { try file("small\(i)", kb: 4) }
        let tree = try await scan()
        let b = bubbles(for: tree, maxCount: 5)
        #expect(b.count == 6)
        #expect(b.prefix(5).allSatisfy { !$0.isAggregate })
        let agg = try #require(b.last)
        #expect(agg.isAggregate && agg.others.count == 25)
        #expect(b.reduce(0) { $0 + $1.size } == tree.size)

        // Items under 1 % of the parent are folded even below maxCount.
        let all = bubbles(for: tree)
        #expect(all.filter { !$0.isAggregate }.count == 10)
        #expect(all.last?.others.count == 20)
    }

    @Test func protectedPaths() {
        // Lot B: ~/Downloads and ~/Library/Caches are SafeRemover protected roots, refused in Radar too.
        for p in ["/", "/System", "/System/Library", "/usr/bin", "/private/var/db", "/Library/Apple/x", "/Users", "/Library",
                  "/Users/me/Downloads", "/Users/me/Library/Caches"] {
            #expect(SpaceNode.isProtected(path: p, home: "/Users/me"))
        }
        for p in ["/Library/Caches", "/Users/me/Downloads/a.zip", "/Applications/Foo.app", "/Users/me/Library/Caches/com.example"] {
            #expect(!SpaceNode.isProtected(path: p, home: "/Users/me"))
        }
        #expect(SpaceNode.isProtected(path: "/Users/me/Library", home: "/Users/me"))
    }

    @Test func listsBootVolume() {
        let vols = SpaceScanner.volumes()
        #expect(vols.first?.isBoot == true)
        #expect((vols.first?.totalCapacity ?? 0) > 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0
    func set(_ n: Int) { lock.withLock { v = n } }
    var value: Int { lock.withLock { v } }

    @Test func selectionKeepsOutermostPaths() {
        #expect(SpaceNode.outermost(["/a/b", "/a", "/a/b/c", "/ab", "/x/y"]) == ["/a", "/ab", "/x/y"])
        #expect(purgeableBubble(5).isAggregate && purgeableBubble(5).name == "Espace purgeable")
    }
}
