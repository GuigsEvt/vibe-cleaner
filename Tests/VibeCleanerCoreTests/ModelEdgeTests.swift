import Foundation
import Testing
@testable import VibeCleanerCore

/// Default selection, quick selections, result pruning, the cleanup journal and uninstall summaries.
@Suite struct ModelEdgeTests {
    func item(_ id: String, size: Int64 = 1, date: Date? = nil, action: ItemAction = .custom("k"), auto: Bool = true) -> ResultItem {
        ResultItem(id: id, name: id, size: size, date: date, action: action, autoSelect: auto)
    }

    // MARK: Default selection

    @Test func groupOffSilencesItsWholeSubtree() {
        let inner = ResultGroup(id: "in", title: "in", items: [item("a")], autoSelect: true)
        let outer = ResultGroup(id: "out", title: "out", groups: [inner], items: [item("b")], autoSelect: false)
        #expect(outer.defaultSelection.isEmpty)
        let top = ResultGroup(id: "top", title: "top", groups: [outer, ResultGroup(id: "x", title: "x", items: [item("c"), item("d", auto: false)])])
        #expect(top.defaultSelection == ["c"])
    }

    @Test func selectionStateOfAnEmptyGroupIsOff() {
        let g = ResultGroup(id: "e", title: "e")
        #expect(g.selectionState(["anything"]) == .off)
        #expect(g.selectedSize([]) == 0)
        #expect(g.isEmpty && g.totalSize == 0 && g.latestDate == nil)
    }

    @Test func sameIdUnderTwoGroupsCountsTwiceInSizes() {
        // The same file listed under an app and in a filter: one id, shown twice.
        let g = ResultGroup(id: "g", title: "g", groups: [ResultGroup(id: "1", title: "1", items: [item("f", size: 10)]),
                                                          ResultGroup(id: "2", title: "2", items: [item("f", size: 10)])])
        #expect(g.selectionState(["f"]) == .on)
        #expect(g.selectedSize(["f"]) == 20, "documenté : les tailles additionnent les doublons d'id")
    }

    @Test func prunedDropsNestedEmptiesButKeepsSelf() {
        let g = ResultGroup(id: "g", title: "g", groups: [ResultGroup(id: "e", title: "e", groups: [ResultGroup(id: "ee", title: "ee")])])
        let p = g.pruned()
        #expect(p.groups.isEmpty)
        #expect(p.id == "g")
    }

    // MARK: Quick selection

    @Test func quickSelectionEdges() {
        #expect(QuickSelection.largest.pick([]).isEmpty)
        #expect(QuickSelection.largest.pick([item("i", action: .none)]).isEmpty)
        #expect(QuickSelection.smallest.pick([item("one")]) == ["one"])
        // Undated items are never picked by date, even when nothing else exists.
        #expect(QuickSelection.newest.pick([item("a"), item("b")]).isEmpty)
        // Duplicated ids count once; ties broken by id so the pick is stable.
        let same = [item("b", size: 5), item("a", size: 5), item("a", size: 5), item("c", size: 5), item("d", size: 5)]
        #expect(QuickSelection.largest.pick(same) == ["a"])
        #expect(QuickSelection.smallest.pick(same) == ["a"])
        // 5 actionable → ceil(1.25) = 2.
        let sized = (1...5).map { item("s\($0)", size: Int64($0)) }
        #expect(QuickSelection.largest.pick(sized) == ["s5", "s4"])
        // Quarter computed on all candidates, picked among dated ones only.
        let d = Date(timeIntervalSince1970: 1_000)
        let mixed = [item("old", date: d), item("new", date: d.addingTimeInterval(10))] + (1...6).map { item("u\($0)") }
        #expect(QuickSelection.oldest.pick(mixed) == ["old", "new"])
    }

    @Test func sortingTiesFallBackToName() {
        let groups = ["b", "a", "C"].map { ResultGroup(id: $0, title: $0, items: [item("\($0)1", size: 5)]) }
        #expect(ResultSort.size.sorted(groups).map(\.title) == ["a", "b", "C"])
        #expect(ResultSort.date.sorted(groups).map(\.title) == ["a", "b", "C"])
        #expect(ResultSort.count.sorted(groups).map(\.title) == ["a", "b", "C"])
        let items = [item("file10"), item("file2")]
        #expect(ResultSort.name.sorted(items).map(\.id) == ["file2", "file10"]) // Finder order
    }

    // MARK: Removing results

    @Test func removingEverythingLeavesNoGroup() {
        let groups = [ResultGroup(id: "g", title: "g", groups: [ResultGroup(id: "s", title: "s", items: [item("a")])], items: [item("b")])]
        #expect(ResultQueries.removing(["a", "b"], from: groups).isEmpty)
        #expect(ResultQueries.removing([], from: groups).map(\.id) == ["g"])
        #expect(ResultQueries.removing(["zzz"], from: groups).first?.allItems.count == 2)
    }

    @Test func adminItemsIgnoreCustomAndNone() {
        let u = URL(fileURLWithPath: "/tmp/x")
        let items = [item("c"), item("n", action: .none), item("d", action: .delete(u, mode: .trash, admin: true)),
                     item("u", action: .delete(u, mode: .trash, admin: false)),
                     item("k", action: .command(executable: "/usr/bin/true", arguments: [], admin: true))]
        #expect(ResultQueries.adminItems(items).map(\.id) == ["d", "k"])
    }

    @Test func copySetAlertEdges() {
        let set = ResultGroup(id: "clutter.dup.1", title: "1", items: [item("a"), item("b")])
        let nested = ResultGroup(id: "clutter.files", title: "f", groups: [ResultGroup(id: "x", title: "x", groups: [set])])
        #expect(ResultQueries.fullySelectedCopySets([nested], selection: ["a", "b"]).map(\.id) == ["clutter.dup.1"])
        #expect(ResultQueries.fullySelectedCopySets([nested], selection: ["a"]).isEmpty)
        #expect(ResultQueries.fullySelectedCopySets([ResultGroup(id: "clutter.sim.0", title: "0")], selection: []).isEmpty)
    }

    // MARK: Selection memory

    @Test func selectionMemoryEdges() throws {
        let g = [ResultGroup(id: "g", title: "g", items: [item("a"), item("b"), item("c", auto: false)])]
        var m = SelectionMemory()
        // Everything unchecked → card off, and it stays off on the next scan.
        m.capture([("junk", g)], selection: [])
        #expect(m.cardsOff == ["junk"])
        #expect(m.selection(for: [("junk", g)]).isEmpty)
        // Only a non-default item checked: the card is on again, defaults stay unchecked.
        m.capture([("junk", g)], selection: ["c"])
        #expect(m.cardsOff.isEmpty)
        #expect(m.selection(for: [("junk", g)]).isEmpty)
        // A module without default items is never marked off.
        let none = [ResultGroup(id: "n", title: "n", items: [item("x", auto: false)])]
        m.capture([("perf", none)], selection: [])
        #expect(!m.cardsOff.contains("perf"))
        // New items found later are selected by default.
        let grown = [ResultGroup(id: "g", title: "g", items: [item("a"), item("b"), item("new")])]
        m.capture([("junk", g)], selection: ["a"])
        #expect(m.selection(for: [("junk", grown)]) == ["a", "new"])
    }

    @Test func selectionMemoryIsCapped() {
        let many = [ResultGroup(id: "g", title: "g", items: (0..<(SelectionMemory.limit + 50)).map { item(String(format: "i%05d", $0)) })]
        var m = SelectionMemory()
        m.capture([("junk", many)], selection: ["i00000"])
        #expect(m.deselected["junk"]?.count == SelectionMemory.limit)
    }

    @Test func selectionMemoryLoadsGarbageAsEmpty() throws {
        let suite = "vc-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("{".utf8), forKey: "k")
        #expect(SelectionMemory.load(key: "k", in: defaults) == SelectionMemory())
        defaults.set("not data", forKey: "k")
        #expect(SelectionMemory.load(key: "k", in: defaults) == SelectionMemory())
        var m = SelectionMemory()
        m.cardsOff = ["x"]
        m.save(key: "k", in: defaults)
        #expect(SelectionMemory.load(key: "k", in: defaults) == m)
    }

    // MARK: Cleanup journal

    @Test func twoRunsInTheSameSecondKeepBothJournals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vc-logs-edge-\(UUID().uuidString)")
        var r1 = ExecutionReport(); r1.processed = ["first"]
        var r2 = ExecutionReport(); r2.processed = ["second"]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let u1 = try CleanupLog(report: r1, module: "junk", dryRun: false, date: date).save(in: root)
        let u2 = try CleanupLog(report: r2, module: "junk", dryRun: false, date: date).save(in: root)
        #expect(u1 != u2)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(files.count == 2)
    }

    @Test func journalTextForEmptyAndSimulatedRuns() {
        let log = CleanupLog(report: ExecutionReport(), module: "radar", dryRun: true, date: Date(timeIntervalSince1970: 0))
        #expect(log.text.contains("(simulation)"))
        #expect(log.text.contains("0 élément(s) traité(s)"))
        #expect(!log.text.contains("Erreurs"))
    }

    @Test func journalSaveFailsOnAnUnwritableRoot() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vc-logs-file-\(UUID().uuidString)")
        try Data().write(to: file)
        #expect(throws: (any Error).self) {
            try CleanupLog(report: ExecutionReport(), module: "junk", dryRun: false).save(in: file)
        }
    }

    // MARK: Uninstall summary

    @Test func summaryLimitBoundaries() {
        let app = InstalledApp(url: URL(fileURLWithPath: "/A/Foo.app"), bundleID: "com.foo", name: "Foo")
        let items = (0..<3).map { ResultItem.file(URL(fileURLWithPath: "/A/nope\($0)"), size: 1) }
        let plan = UninstallPlan(app: app, items: items)
        #expect(!plan.summary(limit: 3).contains("autre(s)"))
        #expect(plan.summary(limit: 0).components(separatedBy: "\n") == [plan.summary(limit: 0).components(separatedBy: "\n")[0], "• … et 3 autre(s)"])
        #expect(!plan.needsAdmin)
        #expect(plan.totalSize == 3)
    }
}
