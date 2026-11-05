import Darwin
import Foundation
import Testing
@testable import VibeCleanerCore

@Suite final class RadarNavigationTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("radar-nav-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func file(_ rel: String, kb: Int, in base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<kb * 1024).map { _ in UInt8.random(in: 1...255) }).write(to: url)
        return url
    }

    func scan() async throws -> SpaceNode { try await SpaceScanner().scan(root: root) { _, _, _ in } }

    func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    @Test func detachUpdatesAncestorsAndOrder() async throws {
        try file("a/sub/big", kb: 64)
        try file("a/small", kb: 4)
        try file("b/f", kb: 40)
        let tree = try await scan()
        #expect(tree.children.map(\.name) == ["a", "b"])
        let a = try #require(tree.node(at: path("a")))
        let big = try #require(tree.node(at: path("a/sub/big")))
        let (treeSize, aSize, files) = (tree.size, a.size, tree.fileCount)
        big.detach()
        #expect(a.size == aSize - big.size && tree.size == treeSize - big.size)
        #expect(tree.fileCount == files - 1)
        #expect(tree.node(at: path("a/sub"))?.size == 0)
        #expect(tree.node(at: path("a/sub/big")) == nil)
        #expect(tree.children.map(\.name) == ["b", "a"])
        #expect(tree.nearest(to: path("a/sub/big/x")) === tree.node(at: path("a/sub")))
    }

    @Test func applyRemovalBuildsLogAndPrunes() async throws {
        try file("a/x", kb: 16)
        try file("b/y", kb: 8)
        let tree = try await scan()
        let x = try #require(tree.node(at: path("a/x")))
        var report = RemovalReport()
        report.removed = [x.url]
        report.freedBytes = x.size
        report.failures = [(URL(fileURLWithPath: path("b/y")), "verrouillé")]
        let before = tree.size
        let log = tree.apply(report, dryRun: false, date: Date(timeIntervalSince1970: 0))
        #expect(log.module == "radar" && !log.dryRun)
        #expect(log.processed == [path("a/x")] && log.freedBytes == report.freedBytes)
        #expect(log.failures == [CleanupLog.Failure(id: path("b/y"), reason: "verrouillé")])
        #expect(tree.size == before - report.freedBytes)
        #expect(tree.node(at: path("b/y")) != nil)

        let logs = root.appendingPathComponent("logs")
        let saved = try log.save(in: logs)
        #expect(saved.lastPathComponent.hasSuffix(" radar.json"))

        // Simulation leaves the tree untouched.
        let y = try #require(tree.node(at: path("b/y")))
        var sim = RemovalReport()
        sim.removed = [y.url]
        let size = tree.size
        #expect(tree.apply(sim, dryRun: true).dryRun)
        #expect(tree.size == size)
    }

    @Test func historyBackForwardSkipsRemoved() async throws {
        try file("a/b/c/f", kb: 4)
        try file("d/f", kb: 4)
        let tree = try await scan()
        let a = try #require(tree.node(at: path("a"))), b = try #require(tree.node(at: path("a/b")))
        let c = try #require(tree.node(at: path("a/b/c"))), d = try #require(tree.node(at: path("d")))
        var h = SpaceHistory()
        #expect(!h.canGoBack && !h.canGoForward)
        h.visit(from: tree, to: a)
        h.visit(from: a, to: b)
        h.visit(from: b, to: b)
        #expect(h.back == [tree.path, a.path])
        #expect(h.goBack(from: b, in: tree) === a)
        #expect(h.canGoForward)
        #expect(h.goForward(from: a, in: tree) === b)
        #expect(h.goBack(from: b, in: tree) === a)
        h.visit(from: a, to: d)
        #expect(!h.canGoForward)

        h = SpaceHistory()
        h.visit(from: tree, to: c)
        h.visit(from: c, to: b)
        h.visit(from: b, to: d)
        c.detach()
        #expect(h.goBack(from: d, in: tree) === b)
        #expect(h.goBack(from: b, in: tree) === tree)
        #expect(h.goBack(from: tree, in: tree) == nil)
    }

    @Test func gaugeSegmentsSumAndClamp() {
        func vol(_ total: Int64, _ free: Int64, _ purgeable: Int64) -> VolumeInfo {
            VolumeInfo(url: URL(fileURLWithPath: "/"), name: "x", totalCapacity: total, availableCapacity: free,
                       purgeableCapacity: purgeable, isInternal: true, isEjectable: false, isBoot: true)
        }
        let g = VolumeGauge(volume: vol(100, 30, 10), selected: 15)
        #expect((g.used, g.selected, g.purgeable, g.free) == (45, 15, 10, 30))
        #expect(g.used + g.selected + g.purgeable + g.free == g.total)
        let big = VolumeGauge(volume: vol(100, 30, 10), selected: 500)
        #expect(big.selected == 60 && big.used == 0)
        let odd = VolumeGauge(volume: vol(100, 90, 50), selected: 0)
        #expect(odd.purgeable == 10 && odd.used == 0)
    }

    @Test func selectionAndTooltip() async throws {
        try file("a/x", kb: 16)
        try file("a/y", kb: 8)
        let tree = try await scan()
        let a = try #require(tree.node(at: path("a"))), x = try #require(tree.node(at: path("a/x")))
        #expect(a.selection(in: [x.path]) == (x.size, false))
        #expect(a.selection(in: [a.path, x.path]) == (a.size, true))
        #expect(x.selection(in: [a.path]).entire)
        #expect(a.selection(in: []) == (0, false))
        let tip = a.tooltip(selected: [x.path])
        #expect(tip.contains("Taille : \(FileSizer.format(a.size))"))
        #expect(tip.contains("Modifié : "))
        #expect(tip.contains("Sélectionné : \(FileSizer.format(x.size))"))
        #expect(a.tooltip(selected: [a.path]).contains("dossier entier"))
        #expect(a.modificationDate != nil)
    }

    @Test func multiRootScanKeepsRealPaths() async throws {
        let cloud = root.appendingPathComponent("home/Library/Mobile Documents/com~apple~CloudDocs")
        let storage = root.appendingPathComponent("home/Library/CloudStorage")
        let f1 = try file("doc.pdf", kb: 12, in: cloud), f2 = try file("GoogleDrive-moi/v.mov", kb: 24, in: storage)
        let roots = SpaceScanner.cloudRoots(home: root.appendingPathComponent("home"))
        #expect(roots.map(\.name) == ["iCloud Drive", "CloudStorage"])
        let missing = (url: root.appendingPathComponent("nope"), name: "Nope")
        let tree = try await SpaceScanner().scan(roots: roots + [missing], name: "Stockage cloud",
                                                 container: root.appendingPathComponent("home/Library")) { _, _, _ in }
        #expect(tree.name == "Stockage cloud" && tree.children.count == 2)
        #expect(tree.size == tree.children.reduce(0) { $0 + $1.size })
        #expect(tree.node(at: f1.path)?.name == "doc.pdf")
        #expect(tree.node(at: f2.path)?.name == "v.mov")
        #expect(tree.children.first { $0.name == "iCloud Drive" }?.path == cloud.path)
        let total = tree.size, v = try #require(tree.node(at: f2.path)), vSize = v.size
        v.detach()
        #expect(tree.node(at: storage.path)?.size == 0 && tree.size == total - vSize)
    }

    @Test func cloudRootsAreProtected() {
        let h = "/Users/me"
        for p in ["\(h)/Library/CloudStorage", "\(h)/Library/CloudStorage/GoogleDrive-moi", "\(h)/Library/Mobile Documents",
                  "\(h)/Library/Mobile Documents/com~apple~CloudDocs"] {
            #expect(SpaceNode.isProtected(path: p, home: h))
        }
        #expect(!SpaceNode.isProtected(path: "\(h)/Library/CloudStorage/GoogleDrive-moi/v.mov", home: h))
        #expect(!SpaceNode.isProtected(path: "\(h)/Library/Mobile Documents/com~apple~CloudDocs/doc.pdf", home: h))
        #expect(SpaceScanner.isDataless(UInt32(SF_DATALESS)) && !SpaceScanner.isDataless(0))
    }
}
