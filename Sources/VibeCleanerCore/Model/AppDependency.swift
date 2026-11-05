import AppKit
import Foundation

/// An app that must be closed before an item can be processed.
/// Identified by bundle id (browsers, Mail) or by bundle path (an app being uninstalled).
public struct AppDependency: Hashable, Sendable {
    public let name: String
    public let bundleID: String?
    public let bundlePath: String?

    public init(name: String, bundleID: String? = nil, bundlePath: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
    }

    @MainActor public var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(matches)
    }

    @MainActor public var isRunning: Bool { !runningApplications.isEmpty }

    @MainActor func matches(_ app: NSRunningApplication) -> Bool {
        if let bundleID, app.bundleIdentifier == bundleID { return true }
        guard let bundlePath else { return false }
        let prefix = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        return [app.bundleURL, app.executableURL].compactMap { $0?.standardizedFileURL.path }
            .contains { $0 == prefix || $0.hasPrefix(prefix + "/") }
    }

    /// Asks the app to quit (or kills it when `force`), then waits up to `timeout`. True when it is gone.
    @MainActor public func quit(force: Bool, timeout: TimeInterval = 8) async -> Bool {
        for app in runningApplications { _ = force ? app.forceTerminate() : app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return !isRunning
    }
}

public extension ScanModule {
    func appDependency(of item: ResultItem) -> AppDependency? { nil }
}
