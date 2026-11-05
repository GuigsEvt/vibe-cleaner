import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct CleanupLogTests {
    @Test func savesOneJSONPerRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-logs-\(UUID().uuidString)")
        var report = ExecutionReport()
        report.processed = ["a"]
        report.freedBytes = 2_000
        report.failures = [("b", "refusé")]
        report.log = ["Corbeille : /tmp/a"]
        let log = CleanupLog(report: report, module: "junk", dryRun: false, date: Date(timeIntervalSince1970: 0))
        let url = try log.save(in: root)
        #expect(url.lastPathComponent == "1970-01-01T00.00.00Z junk.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(CleanupLog.self, from: Data(contentsOf: url)) == log)
        #expect(log.text.contains("Corbeille : /tmp/a"))
        #expect(log.text.contains("b — refusé"))
    }
}
