import Foundation
import Security
@preconcurrency import CoreServices

/// A third-party launchd job read from a plist in one of the scanned LaunchAgents/LaunchDaemons folders.
public struct LaunchItem: Sendable, Hashable {
    public enum Scope: String, Sendable, CaseIterable {
        case userAgent, globalAgent, daemon

        public var needsAdmin: Bool { self != .userAgent }
    }

    public var plist: URL
    public var scope: Scope
    public var label: String
    /// `Program`, else `ProgramArguments[0]`. `BundleProgram` (relative to an app bundle) is not resolved.
    public var program: String?
    public var runAtLoad = false
    public var keepAlive = false
    public var periodic = false
    public var disabled = false
    public var readable = true
    public var hasBundleProgram = false

    /// True when the plist names an absolute program that is provably gone (its nearest existing folder can be
    /// searched: a program under a root-only folder is never "broken"). A plist naming no program is not broken:
    /// launchd simply never runs it (empty Keystone plists, a Label-only plist left by an installer).
    /// Bare names are resolved by launchd through its PATH and are not checked.
    public var isBroken: Bool {
        guard readable, !hasBundleProgram, let program else { return false }
        return program.hasPrefix("/") && SystemJunkScanner.isMissing(program)
    }

    /// launchctl domain target: user agents and /Library/LaunchAgents live in the user's GUI session.
    public func domain(uid: uid_t = getuid()) -> String { scope == .daemon ? "system" : "gui/\(uid)" }

    /// Parses a launchd plist. Returns nil for Apple jobs (`com.apple.*`).
    public static func parse(_ url: URL, scope: Scope) -> LaunchItem? {
        let fileLabel = url.deletingPathExtension().lastPathComponent
        if fileLabel.hasPrefix("com.apple.") { return nil }
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return LaunchItem(plist: url, scope: scope, label: fileLabel, readable: false)
        }
        let label = dict["Label"] as? String ?? fileLabel
        if label.hasPrefix("com.apple.") { return nil }
        var item = LaunchItem(plist: url, scope: scope, label: label)
        item.program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
        item.hasBundleProgram = dict["BundleProgram"] != nil
        item.runAtLoad = dict["RunAtLoad"] as? Bool ?? false
        item.keepAlive = dict["KeepAlive"] is [String: Any] || dict["KeepAlive"] as? Bool == true
        item.periodic = dict["StartInterval"] != nil || dict["StartCalendarInterval"] != nil
        item.disabled = dict["Disabled"] as? Bool ?? false
        return item
    }

    /// Parses a plist, inferring the scope from its folder (e.g. from a `ResultItem.url`).
    public static func parse(_ url: URL) -> LaunchItem? {
        let dir = url.deletingLastPathComponent().path
        let scope: Scope = dir == "/Library/LaunchDaemons" ? .daemon : dir == "/Library/LaunchAgents" ? .globalAgent : .userAgent
        return parse(url, scope: scope)
    }

    /// The `.app` containing the program, if any.
    public var parentApp: URL? {
        guard let program, program.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: program)
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// "Apple", the Team ID, "non signé", or nil when the program is missing or not absolute.
    public var publisher: String? {
        guard let program, program.hasPrefix("/"), FileManager.default.fileExists(atPath: program) else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: program) as CFURL, [], &code) == errSecSuccess, let code else {
            return "non signé"
        }
        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req,
           SecStaticCodeCheckValidity(code, [], req) == errSecSuccess {
            return "Apple"
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String { return team }
        return dict[kSecCodeInfoIdentifier as String] == nil ? "non signé" : "signature ad hoc"
    }
}

/// Reads the `com.apple.LSSharedFileList.SessionLoginItems` list ("Ouvrir à la connexion").
/// Deprecated since 10.11 but still populated on macOS 15–27. Items registered through
/// SMAppService/BTM by other apps are not visible here and have no public API.
enum LoginItems {
    /// `hidden`: "Masquer" ticked in the list, kept when "Réactiver" adds the app back.
    struct Entry: Sendable, Hashable { var name: String; var url: URL?; var hidden = false }

    // A protocol witness keeps the deprecated calls from warning at the call site.
    private protocol Store {
        func entries() -> [Entry]
        func remove(name: String, path: String?) -> Bool
        func insert(_ url: URL, hidden: Bool) -> Bool
    }

    private struct Legacy: Store {
        static let listType = "com.apple.LSSharedFileList.SessionLoginItems"
        static let resolveFlags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)

        @available(macOS, deprecated: 10.11)
        func snapshot() -> (LSSharedFileList, [LSSharedFileListItem])? {
            guard let list = LSSharedFileListCreate(nil, Self.listType as CFString, nil)?.takeRetainedValue() else { return nil }
            var seed: UInt32 = 0
            let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
            return (list, items)
        }

        @available(macOS, deprecated: 10.11)
        func entry(_ item: LSSharedFileListItem) -> Entry {
            let hidden = LSSharedFileListItemCopyProperty(item, kLSSharedFileListLoginItemHidden.takeUnretainedValue())?
                .takeRetainedValue() as? Bool ?? false
            return Entry(name: LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String,
                         url: LSSharedFileListItemCopyResolvedURL(item, Self.resolveFlags, nil)?.takeRetainedValue() as URL?,
                         hidden: hidden)
        }

        @available(macOS, deprecated: 10.11)
        func entries() -> [Entry] { snapshot()?.1.map(entry) ?? [] }

        @available(macOS, deprecated: 10.11)
        func remove(name: String, path: String?) -> Bool {
            guard let (list, items) = snapshot() else { return false }
            var removed = false
            for item in items {
                let e = entry(item)
                // An entry that does not resolve may have been found by name in /Applications (`loginGroup`).
                let unresolved = e.url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
                let match = path.map { e.url?.path == $0 || (unresolved && e.name == name) } ?? (e.url == nil && e.name == name)
                if match { removed = LSSharedFileListItemRemove(list, item) == noErr || removed }
            }
            return removed
        }

        /// Appends the app at the end of the list (how "Réactiver" undoes "Désactiver"), hidden again if it was.
        @available(macOS, deprecated: 10.11)
        func insert(_ url: URL, hidden: Bool) -> Bool {
            guard let list = LSSharedFileListCreate(nil, Self.listType as CFString, nil)?.takeRetainedValue() else { return false }
            let props = hidden ? [kLSSharedFileListLoginItemHidden.takeUnretainedValue(): kCFBooleanTrue] as CFDictionary : nil
            return LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast.takeUnretainedValue(), nil, nil, url as CFURL, props, nil) != nil
        }
    }

    private static var store: any Store { Legacy() }

    static func list() -> [Entry] { store.entries() }

    static func remove(name: String, url: URL?) -> Bool { store.remove(name: name, path: url?.path) }

    static func add(_ url: URL, hidden: Bool = false) -> Bool { store.insert(url, hidden: hidden) }
}
