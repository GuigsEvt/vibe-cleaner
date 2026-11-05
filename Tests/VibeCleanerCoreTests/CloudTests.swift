import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct CloudTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        for d in ["Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage/GoogleDrive-moi@gmail.com",
                  "Library/CloudStorage/OneDrive-Personal", "Library/CloudStorage/Dropbox", "Library/CloudStorage/.cache"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    @Test func serviceNames() {
        #expect(CloudModule.serviceName("GoogleDrive-moi@gmail.com") == "Google Drive (moi@gmail.com)")
        #expect(CloudModule.serviceName("OneDrive-Personal") == "OneDrive (Personal)")
        #expect(CloudModule.serviceName("Dropbox") == "Dropbox")
        #expect(CloudModule.serviceName("Box-Box") == "Box")
        #expect(CloudModule.serviceName("Sync-Pro") == "Sync (Pro)")
    }

    @Test func discoversRoots() {
        let roots = CloudModule.roots(home: home)
        #expect(roots.map(\.service) == ["iCloud Drive", "Dropbox", "Google Drive (moi@gmail.com)", "OneDrive (Personal)"])
    }

    @Test func detectsPinnedAttribute() throws {
        let f = home.appendingPathComponent("Library/CloudStorage/Dropbox/a.bin")
        try Data(count: 10).write(to: f)
        #expect(!CloudModule.hasPinnedAttribute(f))
        let value: [UInt8] = [1]
        #expect(setxattr(f.path, "com.apple.fileprovider.pinned#PX", value, value.count, 0, 0) == 0)
        #expect(CloudModule.hasPinnedAttribute(f))
    }

    @Test func ignoresFilesThatAreNotSynced() async throws {
        try Data(count: 100_000).write(to: home.appendingPathComponent("Library/CloudStorage/Dropbox/gros.bin"))
        let groups = await CloudModule(minSize: 0).scan(context: ModuleContext(dryRun: true, home: home)) { _, _ in }
        #expect(groups.count == 4)
        #expect(groups.allSatisfy { $0.isEmpty && !$0.autoSelect })
    }

    @Test func evictRefusesLocalFilesAndDryRunTouchesNothing() async throws {
        let f = home.appendingPathComponent("Library/CloudStorage/Dropbox/gros.bin")
        try Data(count: 1000).write(to: f)
        let item = ResultItem(name: "gros.bin", url: f, size: 1000, action: .custom(CloudModule.evictKey), autoSelect: false)
        let real = await CloudModule().execute([item], context: ModuleContext(home: home))
        #expect(real.failures.count == 1)
        let dry = await CloudModule().execute([item], context: ModuleContext(dryRun: true, home: home))
        #expect(dry.processed == [f.path])
        #expect(FileManager.default.fileExists(atPath: f.path))
    }
}
