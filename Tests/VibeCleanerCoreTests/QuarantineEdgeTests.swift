import Foundation
import Testing
@testable import VibeCleanerCore

/// Quarantine on a root and files created by the test only.
@Suite struct QuarantineEdgeTests {
    let fm = FileManager.default
    let tmp: URL
    let q: Quarantine

    init() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("vc-q-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        q = Quarantine(root: tmp.appendingPathComponent("Q"))
    }

    func file(_ rel: String, _ text: String = "payload") throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func addingAMissingFileThrowsAndLeavesNoEntry() throws {
        #expect(throws: (any Error).self) { try q.add(tmp.appendingPathComponent("absent"), reason: "x") }
        #expect(q.list().isEmpty)
        let leftovers = (try? fm.contentsOfDirectory(atPath: q.root.path)) ?? []
        #expect(leftovers.isEmpty, "dossier vide laissé dans la quarantaine : \(leftovers)")
    }

    @Test func oddNamesAndFoldersRoundTrip() throws {
        let f = try file("dir with space/l'été \"x\".command", "#!/bin/sh")
        let folder = tmp.appendingPathComponent("Évil.app/Contents")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        let app = folder.deletingLastPathComponent()
        let e1 = try q.add(f, reason: "règle « x »")
        let e2 = try q.add(app, reason: "")
        #expect(Set(q.list().map(\.id)) == [e1.id, e2.id])
        try q.restore(e1.id)
        try q.restore(e2.id)
        #expect(try String(contentsOf: f, encoding: .utf8) == "#!/bin/sh")
        #expect(try fm.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path) == "/etc/hosts")
        #expect(q.list().isEmpty)
    }

    @Test func restoreRecreatesAMissingParent() throws {
        let f = try file("gone/parent/x.bin")
        let e = try q.add(f, reason: "")
        try fm.removeItem(at: tmp.appendingPathComponent("gone"))
        try q.restore(e.id)
        #expect(fm.fileExists(atPath: f.path))
    }

    @Test func restoreNeverOverwritesAFileThatCameBack() throws {
        let f = try file("x.bin", "quarantined")
        let e = try q.add(f, reason: "")
        try Data("new".utf8).write(to: f)
        #expect(throws: (any Error).self) { try q.restore(e.id) }
        #expect(try String(contentsOf: f, encoding: .utf8) == "new")
        #expect(q.list().map(\.id) == [e.id]) // still restorable later
    }

    /// The manifest and the payload share the entry folder: a threat literally named "manifest.json"
    /// is overwritten by the manifest, and "restore" then puts the manifest back in its place.
    @Test func aFileNamedManifestSurvivesTheRoundTrip() throws {
        let f = try file("evil/manifest.json", "original content")
        let e = try q.add(f, reason: "")
        try q.restore(e.id)
        #expect(try String(contentsOf: f, encoding: .utf8) == "original content")
    }

    @Test func entriesWrittenByTheOlderLayoutStillRestore() throws {
        // Layout used by Protection's root path: <root>/<id>/<name> next to manifest.json.
        let id = UUID().uuidString
        let dir = q.root.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = tmp.appendingPathComponent("restored/com.x.plist")
        try Data("plist".utf8).write(to: dir.appendingPathComponent("com.x.plist"))
        let entry = Quarantine.Entry(id: id, originalPath: original.path, reason: "", date: Date())
        try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("manifest.json"))
        try q.restore(id)
        #expect(try String(contentsOf: original, encoding: .utf8) == "plist")
    }

    @Test(arguments: ["", ".", "..", "../..", "a/../..", "/"])
    func purgeAndRestoreRefuseIdsOutsideTheRoot(_ id: String) throws {
        let f = try file("keep.bin")
        let e = try q.add(f, reason: "")
        #expect(throws: (any Error).self) { try q.purge(id) }
        #expect(throws: (any Error).self) { try q.restore(id) }
        #expect(fm.fileExists(atPath: q.root.path))
        #expect(q.list().map(\.id) == [e.id])
        #expect(fm.fileExists(atPath: tmp.path))
    }

    @Test func listSkipsBrokenEntriesAndSortsNewestFirst() throws {
        try fm.createDirectory(at: q.root.appendingPathComponent("broken"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: q.root.appendingPathComponent("broken/manifest.json"))
        try Data().write(to: q.root.appendingPathComponent("stray-file"))
        let a = try q.add(try file("a"), reason: "")
        let b = try q.add(try file("b"), reason: "")
        let ids = q.list().map(\.id)
        #expect(Set(ids) == [a.id, b.id])
        #expect(q.list().map(\.date) == q.list().map(\.date).sorted(by: >))
        #expect(Quarantine(root: tmp.appendingPathComponent("never-created")).list().isEmpty)
    }

    @Test func purgeRemovesOnlyItsEntry() throws {
        let a = try q.add(try file("a"), reason: "")
        let b = try q.add(try file("b"), reason: "")
        try q.purge(a.id)
        #expect(q.list().map(\.id) == [b.id])
        #expect(throws: (any Error).self) { try q.purge(a.id) }
    }
}
