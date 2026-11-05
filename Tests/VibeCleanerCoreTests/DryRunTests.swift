import Foundation
import Testing
@testable import VibeCleanerCore

/// The simulation mode promised in the README: no action kind may touch anything.
@Suite struct DryRunTests {
    @Test func executorTouchesNothingInDryRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-dry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.bin"), b = dir.appendingPathComponent("b.bin"), marker = dir.appendingPathComponent("ran")
        try Data(count: 100).write(to: a)
        try Data(count: 100).write(to: b)

        let items = [
            ResultItem(name: "trash", url: a, size: 100, action: .delete(a, mode: .trash, admin: false)),
            ResultItem(name: "perm", url: b, size: 100, action: .delete(b, mode: .permanent, admin: false)),
            ResultItem(name: "admin", url: a, action: .delete(a, mode: .permanent, admin: true)),
            ResultItem(name: "cmd", action: .command(executable: "/usr/bin/touch", arguments: [marker.path], admin: false)),
            ResultItem(name: "admincmd", action: .command(executable: "/usr/bin/touch", arguments: [marker.path], admin: true)),
            ResultItem(name: "custom", action: .custom("x")),
        ]
        var customCalled = false
        let report = ActionExecutor(remover: SafeRemover(dryRun: true)).run(items) { _, _ in customCalled = true }

        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!customCalled)
        #expect(report.failures.isEmpty)
        #expect(report.processed.count == items.count)
    }
}

@Suite struct AdminDeleteTests {
    @Test func adminTrashMovesIntoTheRootTrash() throws {
        let cmd = try ActionExecutor.adminDeleteCommand(URL(fileURLWithPath: "/Applications/Foo.app"), mode: .trash)
        #expect(cmd[0] == "/bin/sh" && cmd[2] == ActionExecutor.trashScript)
        #expect(Array(cmd[3...]) == ["sh", "/Applications/Foo.app", "/Applications", ActionExecutor.rootTrash])
        #expect(try ActionExecutor.adminDeleteCommand(URL(fileURLWithPath: "/Library/Caches/x"), mode: .permanent)[2] == ActionExecutor.deleteScript)
    }
}
