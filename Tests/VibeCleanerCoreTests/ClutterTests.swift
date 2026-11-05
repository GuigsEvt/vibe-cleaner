import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VibeCleanerCore

extension URL {
    var clutterReal: URL { clutterRealPath(self) }
}

@Suite struct ClutterTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("clutter-\(UUID().uuidString)")
        for d in ["Documents/sub", "Downloads", "Pictures", "Library", ".hidden", "Movies"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    func write(_ path: String, _ data: Data) throws -> URL {
        let url = home.appendingPathComponent(path)
        try data.write(to: url)
        return url.clutterReal
    }

    static func random(_ count: Int, seed: UInt64) -> Data {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        return Data((0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    func scan(_ options: ClutterModule.Options = .init(), exclusions: [String] = []) async -> [ResultGroup] {
        await ClutterModule(options: options).scan(context: ModuleContext(dryRun: true, exclusions: exclusions, home: home)) { _, _ in }
    }

    func group(_ groups: [ResultGroup], _ id: String) -> ResultGroup? { groups.first { $0.id == id } }

    // MARK: Duplicates

    @Test func copyNumbers() {
        #expect(Duplicates.copyNumber("rapport.pdf") == 0)
        #expect(Duplicates.copyNumber("copycat.txt") == 0)
        #expect(Duplicates.copyNumber("rapport copy.pdf") == 1)
        #expect(Duplicates.copyNumber("rapport copy 3.pdf") == 3)
        #expect(Duplicates.copyNumber("rapport copie 2.pdf") == 2)
        #expect(Duplicates.copyNumber("rapport - copie.pdf") == 1)
        #expect(Duplicates.copyNumber("rapport (copie).pdf") == 1)
        #expect(Duplicates.copyNumber("rapport (1).pdf") == 1)
        #expect(Duplicates.copyNumber("Copy of rapport.pdf") == 1)
    }

    @Test func findsDuplicatesAndKeepsOneCopy() async throws {
        let content = Self.random(200 * 1024, seed: 1)
        let original = try write("Documents/rapport.bin", content)
        let inDownloads = try write("Downloads/rapport.bin", content)
        let copy = try write("Documents/sub/rapport copy.bin", content)
        let copie = try write("Documents/rapport copie.bin", content)
        let numbered = try write("Documents/rapport (1).bin", content)
        _ = try write("Library/rapport.bin", content)
        _ = try write(".hidden/rapport.bin", content)
        // Same size, different head; same size, same head but different tail.
        _ = try write("Documents/other-head.bin", Self.random(200 * 1024, seed: 2))
        var tail = content
        tail[150 * 1024] ^= 0xFF
        _ = try write("Documents/other-tail.bin", tail)
        // A hard link frees nothing.
        let lone = try write("Documents/lone.bin", Self.random(150 * 1024, seed: 3))
        try FileManager.default.linkItem(at: lone, to: home.appendingPathComponent("Movies/lone-link.bin"))
        // Under the size threshold.
        let small = Self.random(50 * 1024, seed: 4)
        _ = try write("Documents/small.bin", small)
        _ = try write("Downloads/small.bin", small)

        let dups = try #require(group(await scan(), "clutter.duplicates"))
        #expect(dups.groups.count == 1)
        let set = try #require(dups.groups.first)
        #expect(Set(set.items.compactMap(\.url?.lastPathComponent)).count == 4)
        #expect(set.items.count == 5)
        #expect(set.defaultSelection == Set([inDownloads, copy, copie, numbered].map(\.path)))
        #expect(!set.defaultSelection.contains(original.path))
    }

    @Test func olderAndDeeperCopiesAreSelectedFirst() throws {
        let now = Date()
        let a = ClutterEntry(url: home.appendingPathComponent("Documents/x.bin"), size: 1, allocated: 1, modified: now.addingTimeInterval(-100), accessed: nil, isImage: false)
        let b = ClutterEntry(url: home.appendingPathComponent("Pictures/x.bin"), size: 1, allocated: 1, modified: now, accessed: nil, isImage: false)
        #expect(Duplicates.ordered([a, b], home: home).first?.url == b.url)
        let deep = ClutterEntry(url: home.appendingPathComponent("Documents/sub/x.bin"), size: 1, allocated: 1, modified: now, accessed: nil, isImage: false)
        #expect(Duplicates.ordered([deep, b], home: home).first?.url == b.url)
    }

    @Test func honoursExclusions() async throws {
        let content = Self.random(120 * 1024, seed: 5)
        _ = try write("Documents/a.bin", content)
        _ = try write("Documents/sub/a.bin", content)
        let groups = await scan(exclusions: [home.appendingPathComponent("Documents/sub").path])
        #expect(group(groups, "clutter.duplicates")?.isEmpty ?? true)
    }

    // MARK: Similar images

    /// Random 8×6 grid of gray blocks, optionally brightened.
    static func image(seed: UInt64, brighten: CGFloat = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let values = random(48, seed: seed)
        for (i, v) in values.enumerated() {
            let g = min(1, CGFloat(v) / 255 + brighten)
            ctx.setFillColor(red: g, green: g * 0.9, blue: g * 0.8, alpha: 1)
            ctx.fill(CGRect(x: (i % 8) * 50, y: (i / 8) * 50, width: 50, height: 50))
        }
        return ctx.makeImage()!
    }

    func save(_ image: CGImage, _ path: String, type: UTType, quality: Double = 0.9) throws -> URL {
        let url = home.appendingPathComponent(path)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url.clutterReal
    }

    @Test func hashDistances() throws {
        let a = try #require(ImageHash(image: Self.image(seed: 10)))
        let near = try #require(ImageHash(image: Self.image(seed: 10, brighten: 0.03)))
        let far = try #require(ImageHash(image: Self.image(seed: 11)))
        #expect(a.distance(to: near) <= ImageHash.threshold)
        #expect(a.distance(to: far) > 60)
    }

    @Test func groupsSimilarImagesWithoutSelecting() async throws {
        let png = try save(Self.image(seed: 20), "Pictures/plage.png", type: .png)
        let jpg = try save(Self.image(seed: 20, brighten: 0.02), "Pictures/plage-retouche.jpg", type: .jpeg, quality: 0.6)
        _ = try save(Self.image(seed: 21), "Pictures/montagne.png", type: .png)
        let tiny = CGContext(data: nil, width: 100, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let tinyURL = try save(tiny, "Pictures/tiny.png", type: .png)
        #expect(ImageHash(url: tinyURL) == nil)

        var o = ClutterModule.Options()
        o.imageMinSize = 0
        let similar = try #require(group(await scan(o), "clutter.similar"))
        #expect(similar.groups.count == 1)
        #expect(Set(similar.allItems.compactMap(\.url)) == [png, jpg])
        #expect(similar.defaultSelection.isEmpty)
    }

    // MARK: Large & old

    @Test func sizeBuckets() {
        #expect(ClutterModule.SizeBucket(60_000_000) == .medium)
        #expect(ClutterModule.SizeBucket(2_000_000_000) == .big)
        #expect(ClutterModule.SizeBucket(6_000_000_000) == .huge)
    }

    @Test func largeFilesUseAllocatedSizeAndAge() async throws {
        let big = try write("Movies/film.mov", Self.random(400 * 1024, seed: 30))
        _ = try write("Movies/petit.mov", Self.random(100 * 1024, seed: 31))
        let sparse = home.appendingPathComponent("Movies/disque.img")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let fh = try FileHandle(forWritingTo: sparse)
        try fh.truncate(atOffset: 2_000_000_000)
        try fh.close()

        var o = ClutterModule.Options()
        o.largeMinSize = 300 * 1024
        let recent = try #require(group(await scan(o), "clutter.large"))
        #expect(recent.allItems.map(\.url) == [big])
        #expect(!recent.allItems.contains { $0.url == sparse.clutterReal })
        #expect(recent.groups.first?.id == "clutter.large.recent.\(ClutterModule.SizeBucket.medium.rawValue)")
        #expect(recent.defaultSelection.isEmpty)

        o.now = Date().addingTimeInterval(400 * 86_400)
        let old = try #require(group(await scan(o), "clutter.large"))
        #expect(old.groups.first?.id == "clutter.large.old.\(ClutterModule.SizeBucket.medium.rawValue)")
    }

    // MARK: Downloads

    func zip(_ source: URL, to dest: String) throws -> URL {
        let out = home.appendingPathComponent(dest)
        let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, out.path])
        #expect(r.ok)
        return out.clutterReal
    }

    @Test func downloadsSelectOnlyOldInstallers() async throws {
        let staging = home.appendingPathComponent("staging/Outil.app/Contents")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: staging.appendingPathComponent("Info.plist"))
        let appZip = try zip(staging.deletingLastPathComponent(), to: "Downloads/Outil.zip")
        let notes = home.appendingPathComponent("staging/notes.txt")
        try Data("bonjour".utf8).write(to: notes)
        let dataZip = try zip(notes, to: "Downloads/notes.zip")
        let dmg = try write("Downloads/Setup.dmg", Data(count: 1000))
        let doc = try write("Downloads/facture.pdf", Data(count: 1000))
        _ = dataZip

        let fresh = try #require(group(await scan(), "clutter.downloads"))
        #expect(fresh.defaultSelection.isEmpty)
        #expect(fresh.allItems.count == 4)

        var o = ClutterModule.Options()
        o.now = Date().addingTimeInterval(60 * 86_400)
        // Only an installer of an installed app, never a .zip (lot D).
        var m = ClutterModule(options: o)
        m.installedAppNames = { _ in ["Setup", "Outil"] }
        let old = try #require(group(await m.scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }, "clutter.downloads"))
        #expect(old.defaultSelection == Set([dmg.path]))
        #expect(old.allItems.contains { $0.url == appZip })
        #expect(old.allItems.contains { $0.url == doc })
    }

    // MARK: Execution

    @Test func dryRunKeepsFilesAndDeduplicatesItems() async throws {
        let f = try write("Documents/a.bin", Data(count: 10))
        let item = ResultItem(name: "a.bin", url: f, size: 10, action: .delete(f, mode: .trash, admin: false))
        let r = await ClutterModule().execute([item, item], context: ModuleContext(dryRun: true, home: home))
        #expect(r.processed == [f.path])
        #expect(FileManager.default.fileExists(atPath: f.path))
    }
}

extension ClutterTests {
    @Test func skipsSourceRepositories() async throws {
        let content = Self.random(200 * 1024, seed: 9)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/repo/.git"), withIntermediateDirectories: true)
        _ = try write("Documents/repo/model.bin", content)
        _ = try write("Documents/model.bin", content)
        let dups = group(await scan(), "clutter.duplicates")
        #expect(dups?.groups.isEmpty ?? true)
    }
}
