import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct ProtectionTests {
    func tempHome() throws -> URL {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("vc-prot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        return h
    }

    @Test func parsesYaraOutput() {
        let hits = ProtectionModule.parseYARA("MACOS_ADLOAD_A /Users/x/Downloads/a b.dmg\nXProtect_Foo /tmp/z\n")
        #expect(hits.count == 2)
        #expect(hits[0].rule == "MACOS_ADLOAD_A")
        #expect(hits[0].path == "/Users/x/Downloads/a b.dmg")
    }

    @Test func flagsSuspiciousLocations() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(ProtectionModule.isSuspiciousLocation(URL(fileURLWithPath: "/Users/Shared/agent"), home: home))
        // A hidden home folder is "à vérifier", not suspicious (lot C).
        #expect(!ProtectionModule.isSuspiciousLocation(URL(fileURLWithPath: "/Users/x/.hidden/run"), home: home))
        #expect(ProtectionModule.isHiddenHomeLocation(URL(fileURLWithPath: "/Users/x/.hidden/run"), home: home))
        #expect(ProtectionModule.isSuspiciousLocation(URL(fileURLWithPath: "/private/tmp/x"), home: home))
        #expect(!ProtectionModule.isSuspiciousLocation(URL(fileURLWithPath: "/Applications/Foo.app/Contents/MacOS/Foo"), home: home))
    }

    @Test func detectsUnsignedHiddenLaunchAgent() throws {
        let home = try tempHome()
        let hidden = home.appendingPathComponent(".cache-x")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let script = hidden.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        let plist: [String: Any] = ["Label": "com.evil.updater", "ProgramArguments": ["/bin/sh", script.path]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: home.appendingPathComponent("Library/LaunchAgents/com.evil.updater.plist"))

        let group = ProtectionModule().scanPersistence(context: ModuleContext(home: home))
        let item = try #require(group.items.first { $0.name == "com.evil.updater" })
        // Listed to check, never ticked by default (lot C).
        #expect(!item.autoSelect)
        #expect(item.detail?.contains("à vérifier") == true)
    }

    @Test func quarantineRoundTrip() throws {
        let home = try tempHome()
        let q = Quarantine(root: home.appendingPathComponent("Q"))
        let f = home.appendingPathComponent("bad.bin")
        try Data([1, 2, 3]).write(to: f)
        let entry = try q.add(f, reason: "test")
        #expect(!FileManager.default.fileExists(atPath: f.path))
        #expect(q.list().map(\.id) == [entry.id])
        try q.restore(entry.id)
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect(q.list().isEmpty)
    }

    @Test func appleBinaryIsValidAndApple() {
        let sig = CodeSignature.check(URL(fileURLWithPath: "/bin/ls"))
        #expect(sig.status == .valid)
        #expect(sig.isApple)
    }
}
