import CoreServices
import Foundation
import Security

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable { case appStore, other }

    public var id: String { url.path }
    public let url: URL
    public let bundleID: String?
    /// Bundle file name without `.app` (what Finder shows; also used for name matching).
    public let name: String
    public let version: String?
    public var size: Int64
    public let teamID: String?
    /// Organisation from the signing certificate ("Developer ID Application: Foo Inc (TEAMID)" → "Foo Inc").
    public let publisher: String?
    public let source: Source
    /// Spotlight `kMDItemLastUsedDate`; nil when never indexed.
    public let lastUsed: Date?
    /// Under /System/Applications: never uninstallable.
    public let isSystem: Bool
    public let isAgent: Bool
    public let appGroups: [String]
    public let privilegedExecutables: [String]
    /// Bundle ids of login items, extensions, XPC services and helper apps shipped inside the bundle.
    public let embeddedBundleIDs: [String]
    /// Sparkle `SUFeedURL` from Info.plist. Not fetched during the scan.
    public let sparkleFeedURL: URL?
    /// Architectures of the main executable; empty when it is not a readable Mach-O file.
    public let archs: Set<CPUArch>
    /// `LSMinimumSystemVersion` from Info.plist.
    public let minimumSystemVersion: String?
    /// The bundle carries the SIP `restricted` flag: installed by macOS itself, wherever it sits.
    public let isRestricted: Bool

    public init(url: URL, bundleID: String?, name: String, version: String? = nil, size: Int64 = 0, teamID: String? = nil,
                publisher: String? = nil, source: Source = .other, lastUsed: Date? = nil, isSystem: Bool = false,
                isAgent: Bool = false, appGroups: [String] = [], privilegedExecutables: [String] = [],
                embeddedBundleIDs: [String] = [], sparkleFeedURL: URL? = nil, archs: Set<CPUArch> = [],
                minimumSystemVersion: String? = nil, isRestricted: Bool = false) {
        self.url = url; self.bundleID = bundleID; self.name = name; self.version = version; self.size = size
        self.teamID = teamID; self.publisher = publisher; self.source = source; self.lastUsed = lastUsed
        self.isSystem = isSystem; self.isAgent = isAgent; self.appGroups = appGroups
        self.privilegedExecutables = privilegedExecutables; self.embeddedBundleIDs = embeddedBundleIDs
        self.sparkleFeedURL = sparkleFeedURL
        self.archs = archs; self.minimumSystemVersion = minimumSystemVersion; self.isRestricted = isRestricted
    }

    /// Stubs whose removal uninstalls nothing: Chrome PWAs, VM proxy apps, Setapp teasers.
    static let proxyPrefixes = ["com.google.chrome.app.", "com.parallels.winapp", "com.parallels.applicationgroupbridge",
                                "com.vmware.proxyapp", "com.codeweavers.crossoverhelper", "com.setapp.teaser"]

    /// Apple apps macOS installs in /Applications (Safari, a link into the Safari cryptex since macOS 13).
    static let systemAppleIDs: Set<String> = ["com.apple.safari"]

    /// Apps under /System, Apple apps installed by macOS (SIP-restricted bundle, Safari), proxy stubs and Vibe Cleaner
    /// itself are never offered for removal. Other Apple apps (Pages from the App Store, Xcode downloaded from the
    /// developer site…) are, like any other app.
    public var isProtected: Bool {
        let system = isSystem || url.standardizedFileURL.path.hasPrefix("/System/")
        guard let id = bundleID?.lowercased() else { return system }
        let apple = id.hasPrefix("com.apple.") && source != .appStore && (isRestricted || Self.systemAppleIDs.contains(id))
        return system || apple || id == ApplicationsModule.selfBundleID || Self.proxyPrefixes.contains { id.hasPrefix($0) }
    }

    public func isUnused(now: Date = Date(), days: Int = 180) -> Bool {
        guard let lastUsed, !isAgent, !isProtected else { return false }
        return now.timeIntervalSince(lastUsed) > Double(days) * 86_400
    }
}

enum AppInventory {
    /// Apps kept elsewhere in the home folder (a tool unzipped in ~/tools, an app left in Downloads), via Spotlight.
    static func spotlightApps(home: URL) -> [URL] {
        let r = Shell.run("/usr/bin/mdfind", ["-onlyin", home.path, "kMDItemContentType == 'com.apple.application-bundle'"])
        return r.ok ? r.stdout.split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0)) } : []
    }

    /// Spotlight finds keep only real apps of the user: not in Library, the Trash, ~/Applications (read directly),
    /// a hidden or build folder, an archive's `__MACOSX` copy or another bundle. Without Full Disk Access, Desktop,
    /// Documents and Downloads are skipped: reading them would show a macOS prompt.
    static func filterSpotlightApps(_ urls: [URL], home: URL, fullDiskAccess: Bool) -> [URL] {
        let h = home.standardizedFileURL.path
        let skipped = (["Library", ".Trash", "Applications"] + (fullDiskAccess ? [] : ["Desktop", "Documents", "Downloads"])).map { "\(h)/\($0)/" }
        let noise: Set<String> = ["__MACOSX", "node_modules", "DerivedData", "Pods", "Carthage"]
        return urls.filter { url in
            let p = url.standardizedFileURL.path
            guard url.pathExtension == "app", p.hasPrefix(h + "/"), !skipped.contains(where: p.hasPrefix) else { return false }
            let parents = url.deletingLastPathComponent().pathComponents.dropFirst(home.pathComponents.count)
            guard !parents.contains(where: { $0.hasPrefix(".") || noise.contains($0)
                                              || ["app", "pkg", "bundle", "framework"].contains(($0 as NSString).pathExtension.lowercased()) })
            else { return false }
            return FileManager.default.fileExists(atPath: p)
        }
    }

    /// `.app` bundles directly in each directory and one level of plain subfolders. Symlinks are skipped.
    static func appURLs(in dirs: [URL]) -> [URL] {
        var out: [URL] = []
        for dir in dirs {
            for entry in children(of: dir) {
                if entry.pathExtension == "app" { out.append(entry); continue }
                guard isPlainDirectory(entry) else { continue }
                out += children(of: entry).filter { $0.pathExtension == "app" }
            }
        }
        return out
    }

    static func children(of dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
    }

    static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isPackage != true && v?.isSymbolicLink != true
    }

    /// The real bundle of an iPhone or iPad app installed on a Mac (`Foo.app/Wrapper/Foo.app`), else nil.
    static func wrappedBundle(_ url: URL) -> URL? {
        children(of: url.appendingPathComponent("Wrapper")).first { $0.pathExtension == "app" }
    }

    static func load(_ url: URL, isSystem: Bool) -> InstalledApp? {
        // iPhone and iPad apps keep their Info.plist and executable in the wrapped bundle, at its root.
        let wrapped = wrappedBundle(url)
        let contents = wrapped ?? url.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Info.plist")
        guard let info = readPlist(plistURL) else { return nil }
        let sign = AppSigning.read(url)
        let receipt = wrapped == nil ? url.appendingPathComponent("Contents/_MASReceipt/receipt")
            : url.appendingPathComponent("Wrapper/iTunesMetadata.plist")
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let agent = (info["LSUIElement"] as? Bool) ?? ((info["LSUIElement"] as? String) == "1")
        return InstalledApp(
            url: url, bundleID: info["CFBundleIdentifier"] as? String, name: url.deletingPathExtension().lastPathComponent,
            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String),
            teamID: sign.teamID, publisher: sign.publisher,
            source: FileManager.default.fileExists(atPath: receipt.path) ? .appStore : .other,
            lastUsed: lastUsedDate(url), isSystem: isSystem, isAgent: agent, appGroups: sign.groups,
            privilegedExecutables: (info["SMPrivilegedExecutables"] as? [String: Any]).map { Array($0.keys) } ?? [],
            embeddedBundleIDs: embeddedBundleIDs(url), sparkleFeedURL: feed,
            archs: (info["CFBundleExecutable"] as? String).map {
                MachO.archs(of: wrapped == nil ? url.appendingPathComponent("Contents/MacOS/\($0)") : contents.appendingPathComponent($0))
            } ?? [],
            minimumSystemVersion: wrapped == nil ? info["LSMinimumSystemVersion"] as? String : nil, isRestricted: isRestricted(url))
    }

    /// lstat(2) flags carry SF_RESTRICTED on what System Integrity Protection guards.
    static func isRestricted(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_flags & UInt32(SF_RESTRICTED) != 0
    }

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func embeddedBundleIDs(_ app: URL) -> [String] {
        let dirs = ["Contents/Library/LoginItems", "Contents/PlugIns", "Contents/XPCServices", "Contents/Helpers", "Contents/Library/Helpers"]
        var ids: [String] = []
        for d in dirs {
            for child in children(of: app.appendingPathComponent(d)) {
                if let id = readPlist(child.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String { ids.append(id) }
            }
        }
        return ids
    }
}

enum AppSigning {
    /// Team id, publisher and app groups from the static signature (no validity check, which hashes the whole bundle).
    static func read(_ url: URL) -> (teamID: String?, publisher: String?, groups: [String]) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return (nil, nil, []) }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess, let dict = info as? [String: Any] else { return (nil, nil, []) }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        var publisher: String?
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String?, let colon = summary.firstIndex(of: ":") {
            var name = summary[summary.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let team, name.hasSuffix(" (\(team))") { name = String(name.dropLast(team.count + 3)) }
            publisher = name.isEmpty ? nil : name
        }
        return (team, publisher, groups)
    }
}
