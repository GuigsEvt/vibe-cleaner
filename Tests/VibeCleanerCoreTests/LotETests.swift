import Darwin
import Foundation
import Testing
@testable import VibeCleanerCore

/// Lot E: Radar, Cloud and menu panel fixes. Temporary folders only; no signal is ever sent, nothing is evicted.
@Suite final class LotETests {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("lot-e-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func file(_ rel: String, kb: Int) throws -> URL {
        let url = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<kb * 1024).map { _ in UInt8.random(in: 1...255) }).write(to: url)
        return url
    }

    // MARK: Cloud

    @Test func evictableOnlyWhenUploadedWithoutConflict() {
        func ok(status: URLUbiquitousItemDownloadingStatus? = .current, uploaded: Bool? = true, uploading: Bool? = false,
                conflicts: Bool? = false, excluded: Bool? = false, ubiquitous: Bool? = true) -> Bool {
            CloudModule.isEvictable(ubiquitous: ubiquitous, excludedFromSync: excluded, status: status,
                                    uploaded: uploaded, uploading: uploading, conflicts: conflicts)
        }
        #expect(ok())
        #expect(ok(status: .downloaded))
        #expect(ok(uploading: nil, conflicts: nil))
        #expect(!ok(uploaded: false))
        #expect(!ok(uploaded: nil))
        #expect(!ok(uploading: true))
        #expect(!ok(conflicts: true))
        #expect(!ok(status: .notDownloaded))
        #expect(!ok(status: nil))
        #expect(!ok(excluded: true))
        #expect(!ok(ubiquitous: false))
        #expect(CloudModule.syncKeys.isSuperset(of: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
                                                     .ubiquitousItemHasUnresolvedConflictsKey]))
    }

    @Test func defaultThresholdAndAge() {
        #expect(CloudModule().minSize == 50 * 1024 * 1024)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let age: TimeInterval = 30 * 86_400
        #expect(CloudModule.isRarelyUsed(now.addingTimeInterval(-31 * 86_400), now: now, age: age))
        #expect(!CloudModule.isRarelyUsed(now.addingTimeInterval(-2 * 86_400), now: now, age: age))
        // No access date: the size threshold alone decides.
        #expect(CloudModule.isRarelyUsed(nil, now: now, age: age))
    }

    @Test func executeRefusesFileInPinnedFolder() async throws {
        let home = base.appendingPathComponent("home")
        let f = try file("home/Library/CloudStorage/Dropbox/Projets/gros.bin", kb: 4)
        let value: [UInt8] = [1]
        #expect(setxattr(f.deletingLastPathComponent().path, "com.apple.fileprovider.pinned#P", value, value.count, 0, 0) == 0)
        let item = ResultItem(name: "gros.bin", url: f, size: 4096, action: .custom(CloudModule.evictKey), autoSelect: false)
        let r = await CloudModule().execute([item], context: ModuleContext(home: home))
        #expect(r.processed.isEmpty)
        #expect(r.failures.first?.reason.contains("toujours conservé") == true)
        #expect(FileManager.default.fileExists(atPath: f.path))
    }

    @Test func pinnedLookupStopsAtRoot() throws {
        let f = try file("root/a/b/x.bin", kb: 1)
        let value: [UInt8] = [1]
        var cache: [String: Bool] = [:]
        #expect(!CloudModule.isPinned(f, root: base.appendingPathComponent("root").path, cache: &cache))
        // A pinned folder above the root does not count.
        #expect(setxattr(base.path, "com.apple.fileprovider.pinned#P", value, value.count, 0, 0) == 0)
        cache = [:]
        #expect(!CloudModule.isPinned(f, root: base.appendingPathComponent("root").path, cache: &cache))
        #expect(setxattr(base.appendingPathComponent("root/a").path, "com.apple.fileprovider.pinned#P", value, value.count, 0, 0) == 0)
        cache = [:]
        #expect(CloudModule.isPinned(f, root: base.appendingPathComponent("root").path, cache: &cache))
    }

    @Test func desktopInsideICloudDriveIsNotCountedTwice() throws {
        let mobile = base.appendingPathComponent("Library/Mobile Documents")
        let cloudDesktop = mobile.appendingPathComponent("com~apple~CloudDocs/Desktop")
        try FileManager.default.createDirectory(at: cloudDesktop, withIntermediateDirectories: true)
        let desktop = base.appendingPathComponent("Desktop")
        try FileManager.default.createSymbolicLink(at: desktop, withDestinationURL: cloudDesktop)
        let documents = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        #expect(CloudModule.isCovered(desktop, by: mobile))
        #expect(CloudModule.isCovered(cloudDesktop, by: mobile))
        #expect(!CloudModule.isCovered(documents, by: mobile))
    }

    // MARK: Radar

    @Test func applyReportsTheNodeSize() async throws {
        let f = try file("a/x", kb: 16)
        let tree = try await SpaceScanner().scan(root: base) { _, _, _ in }
        let x = try #require(tree.node(at: f.path))
        let size = x.size
        var report = RemovalReport()
        report.removed = [x.url]
        report.freedBytes = 1
        #expect(tree.apply(report, dryRun: false).freedBytes == size)
    }

    // MARK: Monitor

    @Test func processStartTimeGuardsAgainstReusedPID() throws {
        let me = getpid()
        let start = try #require(ProcessStopper.startTime(me))
        #expect(ProcessStopper.isSame(me, startedAt: start))
        #expect(!ProcessStopper.isSame(me, startedAt: start + 1))
        #expect(!ProcessStopper.isSame(me, startedAt: nil))
        #expect(!ProcessStopper.isSame(me, startedAt: start, uid: getuid() + 1))
        let sampled = SystemSampler.processes().first { $0.pid == me }
        #expect(sampled?.start == start)
    }

    @Test func uptimeRecommendationOpensNothing() {
        var s = SystemSnapshot()
        s.uptime = 30 * 86_400
        let issue = HealthAssessment(snapshot: s).issues.first { $0.id == "uptime" }
        #expect(issue != nil && issue?.module == nil)
    }
}
