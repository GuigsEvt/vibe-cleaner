import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct ResultQueriesTests {
    static func item(_ id: String, size: Int64 = 0, days: Double? = nil, action: ItemAction = .custom("k"), auto: Bool = true) -> ResultItem {
        ResultItem(id: id, name: id, size: size, date: days.map { Date(timeIntervalSince1970: $0 * 86_400) }, action: action, autoSelect: auto)
    }

    @Test func reviewTitleSaysWhatHappens() {
        let wifi = (0..<10).map { Self.item("privacy.wifi.\($0).net\($0)", action: .command(executable: "/usr/sbin/networksetup", arguments: [], admin: true)) }
        let file = Self.item("/tmp/x", size: 2_000_000, action: .delete(URL(fileURLWithPath: "/tmp/x"), mode: .trash, admin: false))
        #expect(ResultQueries.reviewTitle(wifi, action: "Protéger") == "Oublier 10 réseaux Wi-Fi ?")
        #expect(ResultQueries.reviewTitle(Array(wifi.prefix(1)), action: "Protéger") == "Oublier 1 réseau Wi-Fi ?")
        #expect(ResultQueries.reviewTitle(wifi + [file], action: "Protéger") == "Protéger 11 élément(s), \(FileSizer.format(2_000_000)) ?")
        #expect(ResultQueries.reviewNote(wifi + [file]) == "Dont 10 réseaux Wi-Fi à oublier : il faudra ressaisir leur mot de passe pour s'y reconnecter.")
        #expect(ResultQueries.reviewNote([file]) == nil)
        #expect(ResultQueries.reviewNote(wifi) == "Il faudra ressaisir leur mot de passe pour s'y reconnecter.")
    }

    @Test func sortsGroupsByLatestDateAndCount() {
        let old = ResultGroup(id: "old", title: "A", items: [Self.item("a", days: 1), Self.item("b", days: 2), Self.item("c")])
        let new = ResultGroup(id: "new", title: "B", items: [Self.item("d", days: 10)])
        let none = ResultGroup(id: "none", title: "C", items: [Self.item("e")])
        #expect(ResultSort.date.sorted([none, old, new]).map(\.id) == ["new", "old", "none"])
        #expect(ResultSort.count.sorted([new, none, old]).map(\.id) == ["old", "new", "none"])
        #expect(old.latestDate == Date(timeIntervalSince1970: 2 * 86_400))
        #expect(none.latestDate == nil)
    }

    @Test func filtersBySelection() {
        let a = Self.item("a")
        #expect(ResultFilter.selected.matches(a, ["a"]))
        #expect(!ResultFilter.unselected.matches(a, ["a"]))
        #expect(ResultFilter.all.matches(a, []))
    }

    @Test func quickSelectionPicksAQuarter() {
        let items = (1...8).map { Self.item("i\($0)", size: Int64($0), days: Double($0)) } + [Self.item("info", size: 99, action: .none)]
        #expect(QuickSelection.largest.pick(items) == ["i8", "i7"])
        #expect(QuickSelection.smallest.pick(items) == ["i1", "i2"])
        #expect(QuickSelection.newest.pick(items) == ["i8", "i7"])
        #expect(QuickSelection.oldest.pick(items) == ["i1", "i2"])
        #expect(QuickSelection.largest.pick([Self.item("x", size: 1)]) == ["x"])
        #expect(QuickSelection.newest.pick([Self.item("x", size: 1)]).isEmpty)
    }

    @Test func removingPrunesEmptyGroups() {
        let tree = [ResultGroup(id: "g", title: "G", groups: [ResultGroup(id: "s", title: "S", items: [Self.item("a")])], items: [Self.item("b")]),
                    ResultGroup(id: "h", title: "H", items: [Self.item("c")])]
        let left = ResultQueries.removing(["a", "c"], from: tree)
        #expect(left.map(\.id) == ["g"])
        #expect(left[0].groups.isEmpty)
        #expect(left[0].allItems.map(\.id) == ["b"])
    }

    @Test func listsAdminItems() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let items = [Self.item("a", action: .delete(url, mode: .trash, admin: true)),
                     Self.item("b", action: .command(executable: "/bin/echo", arguments: [], admin: true)),
                     Self.item("c", action: .delete(url, mode: .trash, admin: false)), Self.item("d")]
        #expect(ResultQueries.adminItems(items).map(\.id) == ["a", "b"])
    }

    @Test func detectsFullySelectedCopySets() {
        let set1 = ResultGroup(id: "clutter.dup./a", title: "a", items: [Self.item("a1"), Self.item("a2")])
        let set2 = ResultGroup(id: "clutter.dup./b", title: "b", items: [Self.item("b1"), Self.item("b2")])
        let tree = [ResultGroup(id: "clutter.duplicates", title: "Doublons", groups: [set1, set2]),
                    ResultGroup(id: "clutter.large", title: "Gros", items: [Self.item("l")])]
        let hit = ResultQueries.fullySelectedCopySets(tree, selection: ["a1", "a2", "b2", "l"])
        #expect(hit.map(\.id) == ["clutter.dup./a"])
    }

    @Test func selectionMemoryKeepsDeselectionsOnly() {
        let groups = [ResultGroup(id: "g", title: "G", items: [Self.item("a"), Self.item("b"), Self.item("risky", auto: false)])]
        let other = [ResultGroup(id: "o", title: "O", items: [Self.item("o1")])]
        var memory = SelectionMemory()
        memory.capture([("junk", groups), ("perf", other)], selection: ["a", "risky"])
        #expect(memory.deselected["junk"] == ["b"])
        #expect(memory.cardsOff == ["perf"])
        // Next scan: "b" stays unchecked, the hand-checked risky item is not re-checked, the unchecked card stays off.
        let fresh = groups + [ResultGroup(id: "n", title: "N", items: [Self.item("c")])]
        #expect(memory.selection(for: [("junk", fresh), ("perf", other)]) == ["a", "c"])

        let defaults = UserDefaults(suiteName: "vc-test-\(UUID().uuidString)")!
        memory.save(key: "m", in: defaults)
        #expect(SelectionMemory.load(key: "m", in: defaults) == memory)
    }
}

@Suite struct ExecutionProgressTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    static let items = (1...4).map { ResultItem(id: "i\($0)", name: "i\($0)", action: .custom("k")) }

    @Test func reportsEachItem() async {
        let box = Box()
        let report = await Task {
            ExecutionProgress.$onItem.withValue({ box.add($0.id) }) {
                ActionExecutor(remover: SafeRemover(dryRun: true)).run(Self.items)
            }
        }.value
        #expect(box.all == ["i1", "i2", "i3", "i4"])
        #expect(report.processed.count == 4)
    }

    @Test func cancellingStopsBetweenItems() async {
        let box = Box()
        // Cancels the executing task as the second item starts: it still runs, the next ones are stopped.
        let report = await Task {
            ExecutionProgress.$onItem.withValue({ item in
                box.add(item.id)
                if item.id == "i2" { withUnsafeCurrentTask { $0?.cancel() } }
            }) {
                ActionExecutor(remover: SafeRemover(dryRun: true)).run(Self.items)
            }
        }.value
        #expect(box.all == ["i1", "i2"])
        #expect(report.processed == ["i1", "i2"])
        #expect(report.failures.map(\.id) == ["i3", "i4"])
        #expect(report.failures.allSatisfy { $0.reason == ExecutionProgress.stoppedReason })
    }

    @Test func cancelledTaskSkipsTheAdminBatch() async {
        let items = [ResultItem(id: "root", name: "root", action: .command(executable: "/usr/bin/true", arguments: [], admin: true)),
                     ResultItem(id: "user", name: "user", action: .custom("k"))]
        let report = await Task {
            // Cancelled after the admin item is queued: the batch must not start.
            ExecutionProgress.$onItem.withValue({ item in
                if item.id == "user" { withUnsafeCurrentTask { $0?.cancel() } }
            }) {
                ActionExecutor(remover: SafeRemover(dryRun: true)).run(items)
            }
        }.value
        #expect(report.processed == ["user"])
        #expect(report.failures.map(\.id) == ["root"])
    }
}
