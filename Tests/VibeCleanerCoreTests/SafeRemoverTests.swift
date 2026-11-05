import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct SafeRemoverTests {
    let home = NSHomeDirectory()

    @Test func refusesProtectedRoots() {
        let r = SafeRemover()
        for p in ["/", "/System/Library", "/usr/bin/true", home, "\(home)/Library", "\(home)/Library/Caches", "\(home)/Documents"] {
            #expect(throws: RemovalError.self) { try r.check(URL(fileURLWithPath: p)) }
        }
    }

    @Test func allowsContentsOfCaches() throws {
        try SafeRemover().check(URL(fileURLWithPath: "\(home)/Library/Caches/com.example.app"))
    }

    @Test func honoursUserExclusions() {
        let r = SafeRemover(userExclusions: ["~/Library/Caches/keep"])
        #expect(throws: RemovalError.self) { try r.check(URL(fileURLWithPath: "\(home)/Library/Caches/keep/a.db")) }
    }

    @Test func removesTempFileAndReportsSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("x.bin")
        try Data(count: 10_000).write(to: f)
        let report = SafeRemover().remove([f], mode: .permanent)
        #expect(report.removed == [f])
        #expect(report.freedBytes >= 10_000)
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func dryRunKeepsFile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(count: 100).write(to: f)
        _ = SafeRemover(dryRun: true).remove([f], mode: .permanent)
        #expect(FileManager.default.fileExists(atPath: f.path))
    }
}
