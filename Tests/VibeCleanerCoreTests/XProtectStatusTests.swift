import Foundation
import Testing
@testable import VibeCleanerCore

struct XProtectStatusTests {
    @Test func readsStatusAndVersion() throws {
        let s = try #require(XProtectStatus.parse(status: "XProtect launch scans: enabled\nXProtect background scans: enabled\n",
                                                  version: "Version: 5368 Installed: 2026-10-22 18:02:23 +0000\n"))
        #expect(s.isActive)
        #expect(s.version == "5368")
        #expect(s.installed == Date(timeIntervalSince1970: 1_792_692_143))
    }

    @Test func disabledBackgroundScansIsNotActive() throws {
        let s = try #require(XProtectStatus.parse(status: "XProtect launch scans: enabled\nXProtect background scans: disabled", version: ""))
        #expect(!s.isActive)
        #expect(s.version == nil && s.installed == nil)
    }

    @Test func unknownOutputGivesNothing() {
        #expect(XProtectStatus.parse(status: "error: not supported", version: "") == nil)
    }
}
