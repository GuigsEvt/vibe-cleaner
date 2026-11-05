import Foundation
import Testing
@testable import VibeCleanerCore

/// Lot A: one module per item at execution, bulk boxes, admin review, Vibe Check memory.
@Suite struct LotATests {
    static let url = URL(fileURLWithPath: "/tmp/vc-lot-a")

    static func item(_ id: String, _ action: ItemAction = .delete(url, mode: .trash, admin: false), auto: Bool = true) -> ResultItem {
        ResultItem(id: id, name: id, action: action, autoSelect: auto)
    }
    static func permanent(_ id: String, admin: Bool = false) -> ResultItem { item(id, .delete(url, mode: .permanent, admin: admin)) }
    static func trash(_ id: String, admin: Bool = false) -> ResultItem { item(id, .delete(url, mode: .trash, admin: admin)) }

    // MARK: 1. Each item runs once, in one module

    @Test func sharedItemGoesToTheLeastDestructiveModule() {
        // A leftover cache: permanent in Nettoyage, to the Trash in Applications.
        let jobs = ResultQueries.assignJobs([("junk", [Self.permanent("cache"), Self.permanent("log")]),
                                             ("applications", [Self.trash("cache")])],
                                            selection: ["cache", "log"], preferred: nil)
        #expect(jobs.map { $0.map(\.id) } == [["log"], ["cache"]])
    }

    @Test func nonAdminBeatsAdminThenModuleOrder() {
        let jobs = ResultQueries.assignJobs([("a", [Self.trash("x", admin: true), Self.trash("y")]),
                                             ("b", [Self.trash("x"), Self.trash("y")])],
                                            selection: ["x", "y"], preferred: nil)
        #expect(jobs.map { $0.map(\.id) } == [["y"], ["x"]])
    }

    @Test func reviewedModuleWins() {
        let jobs = ResultQueries.assignJobs([("junk", [Self.permanent("cache")]), ("applications", [Self.trash("cache")])],
                                            selection: ["cache"], preferred: "junk")
        #expect(jobs.map { $0.map(\.id) } == [["cache"], []])
    }

    @Test func quarantineBeatsAnIrreversibleCustomAction() {
        var gone = Self.item("app", .custom("remove"))
        gone.customIsIrreversible = true
        let jobs = ResultQueries.assignJobs([("applications", [gone]), ("protection", [Self.item("app", .custom("quarantine"))])],
                                            selection: ["app"], preferred: nil)
        #expect(jobs.map { $0.map(\.id) } == [[], ["app"]])
    }

    // MARK: 2. Once per module, informational rows left out

    @Test func jobsDropDuplicatesAndInformationalRows() {
        let jobs = ResultQueries.assignJobs([("applications", [Self.trash("a"), Self.trash("b"), Self.trash("a"), Self.item("info", .none)])],
                                            selection: ["a", "b", "info", "unknown"], preferred: nil)
        #expect(jobs.map { $0.map(\.id) } == [["a", "b"]])
    }

    // MARK: 3. Bulk boxes

    static var tree: ResultGroup {
        var manual = ResultGroup(id: "manual", title: "Un par un", items: [Self.trash("m1"), Self.trash("m2")])
        manual.bulkSelectable = false
        let auto = ResultGroup(id: "auto", title: "Auto", items: [Self.trash("b1")])
        return ResultGroup(id: "card", title: "Carte", groups: [manual, auto], items: [Self.trash("own"), Self.item("info", .none)])
    }

    @Test func directTickOnANonBulkGroupTicksItsOwnItems() {
        let manual = Self.tree.groups[0]
        #expect(manual.bulkItems.isEmpty)
        #expect(manual.tickItems.map(\.id) == ["m1", "m2"])
        #expect(Self.tree.tickItems.map(\.id) == ["own", "b1"])
        #expect(ResultQueries.toggling(tick: manual.tickItems, all: manual.allItems, selection: []) == ["m1", "m2"])
    }

    @Test func cardBoxLeavesNonBulkAndInformationalItems() {
        let g = Self.tree
        let ticked = ResultQueries.toggling(tick: g.bulkItems, all: g.allItems, selection: [])
        #expect(ticked == ["own", "b1"])
        // Every bulk item ticked: the box reads checked, and unticking clears the hand-picked ones too.
        #expect(ResultQueries.boxState(tick: g.bulkItems, all: g.allItems, selection: ticked) == .on)
        #expect(ResultQueries.toggling(tick: g.bulkItems, all: g.allItems, selection: ticked.union(["m1", "x"])) == ["x"])
        // Only a hand-picked item: partially checked; a click ticks the bulk items.
        #expect(ResultQueries.boxState(tick: g.bulkItems, all: g.allItems, selection: ["m1"]) == .mixed)
        #expect(ResultQueries.toggling(tick: g.bulkItems, all: g.allItems, selection: ["m1"]) == ["m1", "own", "b1"])
        #expect(ResultQueries.boxState(tick: g.bulkItems, all: g.allItems, selection: []) == .off)
    }

    @Test func boxWithoutBulkItemsReadsTheActionableOnes() {
        var only = ResultGroup(id: "m", title: "M", items: [Self.trash("m1"), Self.trash("m2")])
        only.bulkSelectable = false
        let card = ResultGroup(id: "c", title: "C", groups: [only])
        #expect(card.bulkItems.isEmpty)
        #expect(ResultQueries.boxState(tick: card.bulkItems, all: card.allItems, selection: ["m1"]) == .mixed)
        #expect(ResultQueries.boxState(tick: card.bulkItems, all: card.allItems, selection: ["m1", "m2"]) == .on)
        // Nothing to tick in bulk: a click on an empty box does nothing.
        #expect(ResultQueries.toggling(tick: card.bulkItems, all: card.allItems, selection: []).isEmpty)
    }

    // MARK: 5. Administrator review

    @Test func adminItemsIncludeAdminCustomActions() {
        var custom = Self.item("threat", .custom("remove"))
        custom.customNeedsAdmin = true
        let items = [custom, Self.item("plain", .custom("x")), Self.trash("sys", admin: true), Self.trash("user")]
        #expect(ResultQueries.adminItems(items).map(\.id) == ["threat", "sys"])
    }

    // MARK: 6. Vibe Check memory

    @Test func memoryNeverTurnsOffConfirmedThreats() {
        let threat = ResultGroup(id: "prot.yara", title: "Menaces", items: [Self.item("mal", .custom("q"))])
        let check = ResultGroup(id: "prot.persistence", title: "À vérifier", items: [Self.item("agent", .custom("q"))])
        var memory = SelectionMemory()
        memory.capture([("protection", [threat, check])], selection: [])
        #expect(memory.cardsOff == ["protection"])
        #expect(memory.selection(for: [("protection", [threat, check])]) == ["mal"])

        var partial = SelectionMemory()
        partial.capture([("protection", [threat, check])], selection: ["agent"])
        #expect(partial.selection(for: [("protection", [threat, check])]) == ["mal", "agent"])
    }

    @Test func memoryDoesNotRecordAcceptedRisksAsUnchecked() {
        let groups = [ResultGroup(id: "prot.persistence", title: "P", items: [Self.item("a", .custom("q")), Self.item("ok", .custom("q"))])]
        var memory = SelectionMemory()
        memory.capture([("protection", groups)], selection: ["a"], accepted: ["ok"])
        #expect(memory.deselected["protection"] == nil)
    }
}
