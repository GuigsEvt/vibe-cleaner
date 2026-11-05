import Foundation
import Testing
@testable import VibeCleanerCore

/// Fouillis fixes: hard links never preselected, the Mac's copy kept over an external disk's, similar-image tiles.
@Suite struct ClutterHardeningTests {
    let fm = FileManager.default
    let home: URL

    init() throws {
        let t = fm.temporaryDirectory.appendingPathComponent("vc-f2-clutter-\(UUID().uuidString)")
        try fm.createDirectory(at: t, withIntermediateDirectories: true)
        home = t.path.hasPrefix("/var/") ? URL(fileURLWithPath: "/private" + t.path) : t
    }

    func entry(_ rel: String, modified: Date = Date(), root: URL? = nil) -> ClutterEntry {
        ClutterEntry(url: (root ?? home).appendingPathComponent(rel), size: 300_000, allocated: 300_000, modified: modified, accessed: nil, isImage: false)
    }

    @Test func aHardLinkedCopyIsKeptAndNeverSelected() throws {
        let old = Date().addingTimeInterval(-1000)
        for rel in ["Documents/y.bin", "Documents/a/b/y.bin"] {
            try fm.createDirectory(at: home.appendingPathComponent(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 10).write(to: home.appendingPathComponent(rel))
        }
        try fm.linkItem(at: home.appendingPathComponent("Documents/y.bin"), to: home.appendingPathComponent("Documents/a/y-link.bin"))
        let link = entry("Documents/a/y-link.bin", modified: old)
        let copy = entry("Documents/a/b/y.bin")
        let ordered = Duplicates.ordered([copy, link], home: home)
        #expect(ordered.first?.url == link.url)
        // Kept first (the hard link), the real copy is recoverable.
        let g = ClutterModule.setGroup(ordered, id: "clutter.dup") { _, i in i > 0 }
        #expect(!g.defaultSelection.contains(link.url.path))
        #expect(g.subtitle?.contains("Zéro") != true)
        // A hard-linked extra copy frees nothing and is never preselected.
        let linked = ClutterModule.setGroup([copy, link], id: "clutter.dup") { _, i in i > 0 }
        #expect(linked.defaultSelection.isEmpty)
        #expect(linked.subtitle?.contains("Zéro") == true)
    }

    @Test func theMacCopyIsKeptOverTheExternalDisk() {
        let ext = URL(fileURLWithPath: "/Volumes/Ext")
        let external = entry("x.bin", modified: Date().addingTimeInterval(-10_000), root: ext)
        let mac = entry("Documents/deep/x copy 2.bin")
        #expect(Duplicates.ordered([external, mac], home: home).first?.url == mac.url)
    }

    @Test func similarTilesForRecentAndLargeSets() {
        let now = Date()
        let module = ClutterModule()
        func image(_ name: String, size: Int64, created: Date) -> ClutterEntry {
            ClutterEntry(url: home.appendingPathComponent(name), size: size, allocated: size, modified: created, accessed: nil, isImage: true, created: created)
        }
        let recent = [image("a.jpg", size: 200_000, created: now), image("b.jpg", size: 200_000, created: now)]
        let big = [image("c.jpg", size: 8_000_000, created: now.addingTimeInterval(-90 * 86_400)), image("d.jpg", size: 7_000_000, created: now.addingTimeInterval(-90 * 86_400))]
        func set(_ es: [ClutterEntry]) -> ResultGroup {
            ResultGroup(id: "clutter.sim.\(es[0].url.path)", title: es[0].url.lastPathComponent,
                        items: es.map { ClutterModule.item($0, autoSelect: false) }, autoSelect: false)
        }
        let similar = ResultGroup(id: "clutter.similar", title: "s", groups: [set(recent), set(big)])
        // Recent and large series are filters of the one "Images similaires" card, not cards of their own.
        _ = module
        let tagged = ClutterModule.tagSimilar(similar, entries: recent + big, now: now, freshAge: 30 * 86_400, largeSize: 5_000_000)
        #expect(tagged.facetKeys == ["Quand", "Taille"])
        #expect(tagged.groups.map { $0.tags["Quand"] } == ["Récentes", "Plus anciennes"])
        #expect(tagged.groups.map { $0.tags["Taille"] } == ["Petites", "Grandes"])
        #expect(tagged.groups.allSatisfy { $0.keepsFirst })
        // The box of a series ticks every image but the one to keep.
        #expect(tagged.groups[0].tickItems.map(\.name) == ["b.jpg"])
        #expect(tagged.defaultSelection.isEmpty)
    }

    @Test func aYearInParenthesesIsNotACopyNumber() {
        #expect(Duplicates.copyNumber("Rapport (2024).pdf") == 0)
        #expect(Duplicates.copyNumber("Rapport (2).pdf") == 2)
    }
}
