import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct CloudFiltersTests {
    func item(_ name: String, size: Int64, daysAgo: Double?, now: Date) -> ResultItem {
        let url = URL(fileURLWithPath: "/cloud/\(name)")
        return ResultItem(name: name, url: url, size: size, date: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
                          action: .custom(CloudModule.evictKey), autoSelect: false)
    }

    @Test func rarelyUsedAndFilters() throws {
        let now = Date()
        let drive = ResultGroup(id: "cloud.Google Drive", title: "Google Drive", items: [
            item("film.mov", size: 2_000_000_000, daysAgo: 400, now: now), item("notes.pdf", size: 60_000_000, daysAgo: 2, now: now),
        ])
        let icloud = ResultGroup(id: "cloud.iCloud Drive", title: "iCloud Drive", items: [item("photos.zip", size: 300_000_000, daysAgo: nil, now: now)])
        let groups = CloudModule.filterGroups([drive, icloud], now: now, rarelyUsedAge: 30 * 86_400)
        #expect(groups.map(\.id) == ["cloud.rarely", "cloud.byaccess", "cloud.bysize", "cloud.bykind"])
        #expect(Set(groups[0].items.map(\.name)) == ["film.mov", "photos.zip"])
        #expect(groups[1].groups.map(\.title) == ["Ouverts la semaine dernière", "Ouverts il y a plus d'un an", "Date d'ouverture inconnue"])
        #expect(groups[2].groups.map(\.title) == ["Petits (moins de 250 Mo)", "Moyens (250 Mo à 1 Go)", "Énormes (plus de 1 Go)"])
        #expect(Set(groups[3].groups.map(\.id)) == ["cloud.bykind.videos", "cloud.bykind.documents", "cloud.bykind.archives"])
        #expect(groups.allSatisfy { $0.defaultSelection.isEmpty })
        #expect(CloudModule.filterGroups([], now: now, rarelyUsedAge: 1).isEmpty)
    }
}
