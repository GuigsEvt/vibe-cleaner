import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct LogTests {
    @Test func writesFileOnlyWhenDirectoryIsSet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-techlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = LogFile()
        file.append(level: .info, category: "test", "ignoré")
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        file.directory = dir
        file.append(level: .debug, category: "app", "un", date: Date(timeIntervalSince1970: 0))
        file.append(level: .error, category: "app", "deux", date: Date(timeIntervalSince1970: 0))
        let text = try String(contentsOf: try #require(file.url), encoding: .utf8)
        #expect(text == "1970-01-01T00:00:00Z [debug] [app] un\n1970-01-01T00:00:00Z [error] [app] deux\n")

        file.directory = nil
        file.append(level: .info, category: "app", "trois")
        #expect(try String(contentsOf: dir.appendingPathComponent("vibecleaner.log"), encoding: .utf8) == text)
    }

    @Test func anonymizesHome() {
        #expect(LogFile.anonymized("/Users/bob/Library/Caches", home: "/Users/bob") == "~/Library/Caches")
        #expect(LogFile.anonymized("/tmp/x", home: "/") == "/tmp/x")
    }
}
