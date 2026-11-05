import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct FrenchFormatTests {
    @Test func sizesAreFrenchWhateverTheProcessLocale() {
        let s = FileSizer.format(6_270_000_000)
        #expect(s.contains("6,27") && s.hasSuffix("Go"))
        #expect(FileSizer.format(4_000).hasSuffix("ko"))
        #expect(!FileSizer.format(0).contains("Zero"))
    }

    @Test func datesAreFrench() {
        let d = Date(timeIntervalSince1970: 1_778_314_380)   // 9 May 2026
        #expect(FileSizer.date(d, time: false).contains("mai"))
        let log = CleanupLog(report: ExecutionReport(), module: "junk", dryRun: false, date: d)
        #expect(log.text.contains("mai") && log.text.contains("ko libérés"))
    }

    @Test func sortDirectionFlips() {
        let a = ResultItem(id: "a", name: "a", size: 1, action: .none), b = ResultItem(id: "b", name: "b", size: 2, action: .none)
        #expect(ResultSort.size.sorted([a, b], ascending: false).map(\.id) == ["b", "a"])
        #expect(ResultSort.size.sorted([a, b], ascending: true).map(\.id) == ["a", "b"])
        let g = [ResultGroup(id: "x", title: "A", items: [a]), ResultGroup(id: "y", title: "B", items: [b])]
        #expect(ResultSort.name.sorted(g, ascending: true).map(\.id) == ["y", "x"])
    }
}
