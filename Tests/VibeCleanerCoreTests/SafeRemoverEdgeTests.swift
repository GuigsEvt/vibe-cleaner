import Foundation
import Testing
@testable import VibeCleanerCore

/// Edge cases of the last line of defence. `check` only resolves paths (lstat), it never touches the disk;
/// every real removal below happens in a temporary folder created by the test, in `.permanent` mode
/// (`.trash` would write into the user's real Trash).
@Suite struct SafeRemoverEdgeTests {
    let fm = FileManager.default
    let tmp: URL

    init() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("vc-sr-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    func file(_ rel: String, bytes: Int = 10) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    /// macOS firmlinks: `resolvingSymlinksInPath` turns an existing "/private/var/db" into "/var/db".
    /// The forbidden and protected lists name the /private form, so the short form must be caught too.
    @Test(arguments: ["/private/var/db", "/var/db", "/private/var", "/var", "/private/tmp", "/tmp"])
    func privateAliasesStayProtected(_ path: String) {
        #expect(throws: RemovalError.self) { try SafeRemover(home: "/Users/nobody").check(URL(fileURLWithPath: path)) }
    }

    @Test func contentsOfVarDbStayForbidden() throws {
        // Any existing entry of /private/var/db, read-only lookup.
        let entries = (try? fm.contentsOfDirectory(atPath: "/private/var/db")) ?? []
        let name = try #require(entries.first)
        for base in ["/private/var/db/", "/var/db/"] {
            #expect(throws: RemovalError.self) { try SafeRemover(home: "/Users/nobody").check(URL(fileURLWithPath: base + name)) }
        }
    }

    @Test func dotDotTrailingSlashAndCaseReachProtectedRoots() throws {
        let home = tmp.appendingPathComponent("home")
        try fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        let r = SafeRemover(home: home.path)
        for p in ["\(home.path)/Documents/", "\(home.path)/Library/Caches/../Caches", "\(home.path)/./Documents",
                  "\(home.path)/Library/Caches/..", "\(home.path)/Documents/.."] {
            #expect(throws: RemovalError.self, "\(p)") { try r.check(URL(fileURLWithPath: p)) }
        }
        // The boot volume is case-insensitive: "documents" is the Documents folder.
        let caseInsensitive = fm.fileExists(atPath: home.appendingPathComponent("DOCUMENTS").path)
        if caseInsensitive {
            #expect(throws: RemovalError.self) { try r.check(home.appendingPathComponent("documents")) }
        }
    }

    @Test func symlinkToProtectedFolderIsRefusedAndRemovingALinkKeepsItsTarget() throws {
        let home = tmp.appendingPathComponent("home")
        let docs = home.appendingPathComponent("Documents")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let r = SafeRemover(home: home.path)
        // Resolved before comparison: a link to Documents is refused (over-protective, safe direction).
        let toDocs = tmp.appendingPathComponent("link-to-docs")
        try fm.createSymbolicLink(at: toDocs, withDestinationURL: docs)
        #expect(throws: RemovalError.self) { try r.check(toDocs) }

        // A link to an ordinary folder: removing it removes the link, never the target.
        let target = try file("target/keep.bin")
        let link = tmp.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let report = r.remove([link], mode: .permanent)
        #expect(report.failures.isEmpty)
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
        #expect(fm.fileExists(atPath: target.path))
        #expect(report.freedBytes == 0) // symlinks are not followed by FileSizer
    }

    @Test func exclusionsMatchWholeComponentsOnly() throws {
        let keep = tmp.appendingPathComponent("a/b")
        let r = SafeRemover(userExclusions: [keep.path + "/"], home: "/Users/nobody")
        #expect(throws: RemovalError.self) { try r.check(keep) }
        #expect(throws: RemovalError.self) { try r.check(keep.appendingPathComponent("c d/é'\".txt")) }
        try r.check(tmp.appendingPathComponent("a/bc"))      // same string prefix, other folder
        try r.check(tmp.appendingPathComponent("a"))          // the parent is not excluded
    }

    @Test func exclusionThroughASymlinkCoversTheRealPath() throws {
        let real = tmp.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = tmp.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        let r = SafeRemover(userExclusions: [alias.path], home: "/Users/nobody")
        #expect(throws: RemovalError.self) { try r.check(real.appendingPathComponent("x")) }
        let ctx = ModuleContext(exclusions: [alias.path])
        #expect(ctx.isExcluded(real.appendingPathComponent("x")))
        #expect(!ctx.isExcluded(tmp.appendingPathComponent("realx")))
    }

    @Test func removeContinuesAfterFailuresAndHandlesOddNames() throws {
        let odd = try file("noms/l'été \"quoted\" $HOME `x`.bin", bytes: 5_000)
        let missing = tmp.appendingPathComponent("absent.bin")
        let report = SafeRemover(home: "/Users/nobody").remove([URL(fileURLWithPath: "/System"), missing, odd, odd], mode: .permanent)
        #expect(report.removed == [odd])
        #expect(report.failures.map(\.0) == [URL(fileURLWithPath: "/System"), missing, odd]) // the duplicate fails: already gone
        #expect(report.freedBytes >= 5_000)
        #expect(!fm.fileExists(atPath: odd.path))
    }

    @Test func emptyListIsANoOp() {
        let r = SafeRemover(home: "/Users/nobody").remove([], mode: .permanent)
        #expect(r.removed.isEmpty && r.failures.isEmpty && r.freedBytes == 0)
    }

    @Test func dryRunStillRefusesProtectedPaths() {
        let r = SafeRemover(dryRun: true, home: "/Users/nobody").remove([URL(fileURLWithPath: "/usr/bin/true")], mode: .permanent)
        #expect(r.removed.isEmpty)
        #expect(r.failures.count == 1)
    }

    /// A simulation must not report as removed a file that does not exist.
    @Test func dryRunDoesNotClaimMissingFiles() throws {
        let missing = tmp.appendingPathComponent("never-existed.bin")
        let present = try file("present.bin", bytes: 4_096)
        let r = SafeRemover(dryRun: true, home: "/Users/nobody").remove([missing, present], mode: .trash)
        #expect(r.removed == [present])
        #expect(r.failures.map(\.0) == [missing])
        #expect(fm.fileExists(atPath: present.path))
    }

    @Test func dryRunCountsABrokenSymlinkAsPresent() throws {
        let link = tmp.appendingPathComponent("broken")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: tmp.appendingPathComponent("nowhere").path)
        let r = SafeRemover(dryRun: true, home: "/Users/nobody").remove([link], mode: .permanent)
        #expect(r.removed == [link])
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func folderSizeIgnoresSymlinkedContent() throws {
        _ = try file("dir/a.bin", bytes: 8_192)
        let big = try file("outside/big.bin", bytes: 1 << 20)
        try fm.createSymbolicLink(at: tmp.appendingPathComponent("dir/link"), withDestinationURL: big)
        let size = FileSizer.size(of: tmp.appendingPathComponent("dir"))
        #expect(size >= 8_192 && size < 1 << 20)
        #expect(FileSizer.size(of: tmp.appendingPathComponent("absent")) == 0)
    }
}
