import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VibeCleanerCore

extension ClutterTests {
    func mkdir(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Duplicates

    @Test func bundlesAreComparedAsOneUnit() async throws {
        for (dir, seed) in [("Documents/Outil.app", 50), ("Downloads/Outil.app", 50), ("Documents/sub/Autre.app", 51)] {
            _ = try mkdir(dir + "/Contents/MacOS")
            _ = try write(dir + "/Contents/MacOS/outil", Self.random(80 * 1024, seed: UInt64(seed)))
            _ = try write(dir + "/Contents/Info.plist", Self.random(40 * 1024, seed: 7))
        }
        let groups = await scan()
        let dups = try #require(group(groups, "clutter.duplicates"))
        let set = try #require(dups.groups.first)
        #expect(dups.groups.count == 1)
        #expect(set.items.map(\.url) == [home.appendingPathComponent("Documents/Outil.app").clutterReal,
                                         home.appendingPathComponent("Downloads/Outil.app").clutterReal])
        #expect(dups.defaultSelection == [home.appendingPathComponent("Downloads/Outil.app").clutterReal.path])
        // Files inside a bundle are never offered on their own.
        #expect(!dups.allItems.contains { $0.url?.path.contains(".app/") == true })
        #expect(set.tags["Type"] == "Applications")
    }

    @Test func duplicateTilesAndKinds() async throws {
        let content = Self.random(200 * 1024, seed: 60)
        _ = try mkdir("Desktop")
        _ = try write("Desktop/photo.bin", content)
        _ = try write("Documents/photo.bin", content)
        let other = Self.random(150 * 1024, seed: 61)
        _ = try write("Movies/clip.bin", other)
        _ = try write("Pictures/clip.bin", other)

        let groups = await scan()
        let dups = try #require(group(groups, "clutter.duplicates"))
        #expect(dups.groups.count == 2)
        // Recent, Desktop, Documents and kinds are filters of the one card, not cards of their own.
        #expect(!groups.contains { $0.id.hasPrefix("clutter.dup") && $0.id != "clutter.duplicates" })
        #expect(dups.facetKeys == ["Quand", "Où", "Type"])
        let photo = try #require(dups.groups.first { $0.title == "photo.bin" })
        #expect(photo.tags["Où"] == "Bureau" && photo.tags["Quand"] == "Récents")
        #expect(dups.groups.first { $0.title == "clip.bin" }?.tags["Où"] == "Ailleurs")
        #expect(dups.facetCounts("Quand") == ["Récents": 2])
        // One box per set, ticking every copy but the one kept.
        #expect(photo.keepsFirst && photo.tickItems.map(\.id) == Array(photo.items.dropFirst().map(\.id)))

        var o = ClutterModule.Options()
        o.now = Date().addingTimeInterval(200 * 86_400)
        #expect(group(await scan(o), "clutter.duplicates")?.facetCounts("Quand") == ["Plus anciens": 2])
    }

    @Test func alertsWhenEveryCopyIsSelected() async throws {
        let content = Self.random(200 * 1024, seed: 62)
        _ = try write("Documents/a.bin", content)
        _ = try write("Downloads/a.bin", content)
        let groups = await scan()
        let ids = Set(try #require(group(groups, "clutter.duplicates")).allItems.map(\.id))
        #expect(ResultQueries.fullySelectedCopySets(groups, selection: groups.reduce(into: Set<String>()) { $0.formUnion($1.defaultSelection) }).isEmpty)
        #expect(Set(ResultQueries.fullySelectedCopySets(groups, selection: ids).map(\.title)) == ["a.bin"])
    }

    @Test func vibeCheckKeepsDownloadsDuplicatesAndLargeFiles() async throws {
        let content = Self.random(200 * 1024, seed: 63)
        _ = try write("Documents/rapport.bin", content)
        let dl = try write("Downloads/rapport.bin", content)
        _ = try write("Documents/sub/rapport copy.bin", content)
        let other = Self.random(150 * 1024, seed: 64)
        _ = try write("Documents/seul.bin", other)
        _ = try write("Movies/seul.bin", other)

        var o = ClutterModule.Options.vibeCheck
        o.largeMinSize = 120 * 1024
        let groups = await scan(o)
        #expect(groups.map(\.id) == ["clutter.duplicates", "clutter.large"])
        let dups = try #require(group(groups, "clutter.duplicates"))
        #expect(dups.groups.count == 1 && dups.allItems.count == 3)
        #expect(dups.defaultSelection == [dl.path])
    }

    @Test func externalVolumesAreOptional() async throws {
        let volume = FileManager.default.temporaryDirectory.appendingPathComponent("volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let content = Self.random(200 * 1024, seed: 65)
        _ = try write("Documents/film.bin", content)
        try content.write(to: volume.appendingPathComponent("film.bin"))
        #expect(group(await scan(), "clutter.duplicates")?.isEmpty ?? true)
        var o = ClutterModule.Options()
        o.externalVolumes = [volume]
        let dups = try #require(group(await scan(o), "clutter.duplicates"))
        #expect(dups.allItems.compactMap(\.url) .contains(volume.appendingPathComponent("film.bin").clutterReal))
    }

    @Test func fileKinds() {
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.jpg")) == .pictures)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.mov")) == .videos)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.mp3")) == .audio)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.zip")) == .archives)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.dmg")) == .archives)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.pdf")) == .documents)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.docx")) == .documents)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.app")) == .applications)
        #expect(FileKind(url: URL(fileURLWithPath: "/a/b.xyz123")) == .other)
    }

    // MARK: Best to keep

    /// The test pattern drawn small then scaled up: same picture, softer edges.
    static func blurred(_ image: CGImage, factor: Int = 8) -> CGImage {
        func draw(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()!
        }
        return draw(draw(image, image.width / factor, image.height / factor), image.width, image.height)
    }

    static func noisy(_ image: CGImage, amount: Int = 60, seed: UInt64) -> CGImage {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let noise = random(w * h, seed: seed)
        for i in 0..<(w * h) {
            let d = Int(noise[i]) % (2 * amount + 1) - amount
            for c in 0..<3 { px[i * 4 + c] = UInt8(clamping: Int(px[i * 4 + c]) + d) }
        }
        return ctx.makeImage()!
    }

    @Test func qualityMetrics() throws {
        let sharp = try #require(ImageQuality(image: Self.image(seed: 70)))
        let soft = try #require(ImageQuality(image: Self.blurred(Self.image(seed: 70))))
        let grainy = try #require(ImageQuality(image: Self.noisy(Self.image(seed: 70), seed: 3)))
        let flat = try #require(ImageQuality(image: Self.image(seed: 70, brighten: 0.9)))
        #expect(sharp.sharpness > 2 * soft.sharpness)
        #expect(grainy.noise > 3 * sharp.noise)
        #expect(sharp.dynamicRange > flat.dynamicRange)
        #expect(ImageQuality.best([soft, sharp, grainy], pixels: [1, 1, 1]) == 1)
        #expect(soft.flaws(in: [soft, sharp]) == ["Floue"])
        #expect(grainy.flaws(in: [grainy, sharp]).contains("Bruitée"))
        #expect(sharp.flaws(in: [soft, sharp, grainy]).isEmpty)
    }

    @Test func similarImagesPutTheBestFirst() async throws {
        let base = Self.image(seed: 71)
        let soft = try save(Self.blurred(base, factor: 3), "Pictures/a-floue.png", type: .png)
        let sharp = try save(base, "Pictures/b-nette.png", type: .png)
        #expect(try #require(ImageHash(url: soft)).distance(to: try #require(ImageHash(url: sharp))) <= ImageHash.threshold)
        var o = ClutterModule.Options()
        o.imageMinSize = 0
        let similar = try #require(group(await scan(o), "clutter.similar"))
        let items = try #require(similar.groups.first?.items)
        #expect(items.map(\.url) == [sharp, soft])
        #expect(items[0].detail?.hasPrefix("Meilleure à garder") == true)
        #expect(similar.defaultSelection.isEmpty)
    }

    // MARK: Large files and downloads

    @Test func largeFileFilters() async throws {
        _ = try write("Movies/film.mov", Self.random(400 * 1024, seed: 72))
        _ = try write("Documents/notes.pdf", Self.random(400 * 1024, seed: 73))
        var o = ClutterModule.Options()
        o.largeMinSize = 300 * 1024
        let groups = await scan(o)
        let large = try #require(group(groups, "clutter.large"))
        #expect(large.facetKeys == ["Ouverture", "Taille", "Type"])
        #expect(large.facetCounts("Type") == ["Vidéos": 1, "Documents": 1])
        #expect(large.facetCounts("Ouverture") == ["Ouverts récemment": 1] && large.defaultSelection.isEmpty)
        #expect(!groups.contains { $0.id.hasPrefix("clutter.large") && $0.id != "clutter.large" })
        #expect(FileFilters.accessBucket(Date().addingTimeInterval(-40 * 86_400), now: Date()).title == "Ouverts il y a plus d'un mois")
        #expect(FileFilters.accessBucket(Date().addingTimeInterval(-400 * 86_400), now: Date()).order == 4)
        #expect(FileFilters.sizeBucket(300_000_000).title == "Moyens (250 Mo à 1 Go)")
    }

    func setXattr(_ url: URL, _ name: String, _ data: Data) {
        let r = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, 0) }
        #expect(r == 0)
    }

    @Test func downloadsGroupedBySource() async throws {
        let slack = try write("Downloads/devis.pdf", Data(count: 100))
        let safari = try write("Downloads/outil.zip", Data(count: 100))
        let unknown = try write("Downloads/vieux.txt", Data(count: 100))
        func plist(_ urls: [String]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0) }
        setXattr(slack, DownloadOrigin.whereFromsKey, try plist(["https://files.slack.com/files-pri/T01-F02/devis.pdf", "https://acme.slack.com/"]))
        setXattr(slack, DownloadOrigin.quarantineKey, Data("0083;65f1c2a0;Slack;".utf8))
        setXattr(safari, DownloadOrigin.whereFromsKey, try plist(["https://www.example.com/outil.zip"]))
        setXattr(safari, DownloadOrigin.quarantineKey, Data("0083;65f1c2a0;Safari;ABCD".utf8))
        #expect(DownloadOrigin.source(slack) == ("Slack", "Espace « acme »"))
        #expect(DownloadOrigin.source(safari) == ("Safari", "example.com"))
        #expect(DownloadOrigin.source(unknown) == ("Origine inconnue", "Adresse inconnue"))

        let downloads = try #require(group(await scan(), "clutter.downloads"))
        #expect(downloads.facetKeys == ["Source"])
        #expect(downloads.facetCounts("Source") == ["Origine inconnue": 1, "Safari": 1, "Slack": 1])
    }
}
