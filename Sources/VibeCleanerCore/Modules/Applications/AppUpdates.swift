import Foundation

/// Newer versions of installed apps: the App Store for its apps, the Sparkle feed (`SUFeedURL`) for the others.
/// Only reads: the update itself is installed by the App Store or by the app.
enum AppUpdates {
    struct Update: Sendable, Equatable {
        let app: InstalledApp
        let installed: String
        let available: String
        let fromStore: Bool
    }

    typealias Fetch = @Sendable (URL) async -> Data?

    static let maxBytes = 2_000_000

    /// No cookies or cache kept, HTTPS only even after a redirect: a feed moved to plain HTTP could be rewritten on the way.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: HTTPSOnly(), delegateQueue: nil)
    }()

    /// Reads at most `maxBytes`: a huge or endless answer is dropped instead of filling memory.
    static let fetch: Fetch = { url in
        guard url.scheme == "https", let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= Int64(maxBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch { return nil }
        return data
    }

    /// Numeric comparison of dotted versions ("1.10" > "1.9", "2.0" == "2"); text parts compare as text.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let split = { (v: String) in v.split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let a = split(candidate), b = split(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "0", y = i < b.count ? b[i] : "0"
            if let m = Int(x), let n = Int(y) {
                if m != n { return m > n }
            } else if x != y {
                return x.compare(y, options: .numeric) == .orderedDescending
            }
        }
        return false
    }

    /// Highest release of an appcast for this macOS, skipping beta channels: (build, display version).
    static func latest(appcast data: Data, os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> (build: String, short: String?)? {
        let parser = XMLParser(data: data)
        let reader = AppcastReader()
        parser.delegate = reader
        guard parser.parse() || !reader.items.isEmpty else { return nil }
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return reader.items
            .filter { $0.channel == nil && ($0.minimumSystem.map { !isNewer($0, than: osString) } ?? true) }
            .compactMap { i in i.build.map { ($0, i.short) } }
            .max { isNewer($1.0, than: $0.0) }
    }

    /// Version of the App Store lookup answer.
    static func storeVersion(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first else { return nil }
        return first["version"] as? String
    }

    static func lookupURL(bundleID: String, country: String = Locale.current.region?.identifier ?? "US") -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")
        c?.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "entity", value: "desktopSoftware"),
                         URLQueryItem(name: "country", value: country.lowercased())]
        return c?.url
    }

    static func check(_ app: InstalledApp, fetch: Fetch) async -> Update? {
        guard let short = app.version else { return nil }
        if app.source == .appStore {
            guard let id = app.bundleID, let url = lookupURL(bundleID: id), let data = await fetch(url),
                  let v = storeVersion(data), isNewer(v, than: short) else { return nil }
            return Update(app: app, installed: short, available: v, fromStore: true)
        }
        // Sparkle compares builds (CFBundleVersion with sparkle:version); plain http feeds are not trusted.
        guard let feed = app.sparkleFeedURL, feed.scheme == "https", let data = await fetch(feed),
              let last = latest(appcast: data) else { return nil }
        let build = AppInventory.readPlist(app.url.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String ?? short
        guard isNewer(last.build, than: build) else { return nil }
        return Update(app: app, installed: short, available: last.short ?? last.build, fromStore: false)
    }

    /// Checks every app, eight at a time; an unreachable server only hides that app.
    static func find(_ apps: [InstalledApp], fetch: @escaping Fetch = fetch) async -> [Update] {
        let candidates = apps.filter { $0.source == .appStore || $0.sparkleFeedURL != nil }
        return await withTaskGroup(of: Update?.self) { group in
            var next = 0, found: [Update] = []
            func add() {
                guard next < candidates.count else { return }
                let app = candidates[next]
                next += 1
                group.addTask { Task.isCancelled ? nil : await check(app, fetch: fetch) }
            }
            for _ in 0..<8 { add() }
            for await u in group {
                if let u { found.append(u) }
                add()
            }
            return found.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        }
    }

    static func item(_ u: Update) -> ResultItem {
        let how = u.fromStore ? "App Store" : "à installer depuis l'app (menu « Rechercher les mises à jour »)"
        return ResultItem(id: "applications.update.\(u.app.url.path)", name: u.app.name,
                          detail: "\(u.installed) → \(u.available) · \(how)", url: u.app.url,
                          action: .command(executable: "/usr/bin/open",
                                           arguments: [u.fromStore ? "macappstore://showUpdatesPage" : u.app.url.path], admin: false),
                          autoSelect: false)
    }
}

/// Collects `<item>` entries of a Sparkle appcast; versions may be enclosure attributes or child elements.
private final class AppcastReader: NSObject, XMLParserDelegate {
    struct Item { var build: String?, short: String?, channel: String?, minimumSystem: String? }
    var items: [Item] = []
    private var current: Item?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = Item() }
        if name == "enclosure", var item = current {
            item.build = item.build ?? attributes["sparkle:version"]
            item.short = item.short ?? attributes["sparkle:shortVersionString"]
            current = item
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item": if let c = current { items.append(c) }; current = nil
        case "sparkle:version" where !value.isEmpty: current?.build = value
        case "sparkle:shortVersionString" where !value.isEmpty: current?.short = value
        case "sparkle:channel" where !value.isEmpty: current?.channel = value
        case "sparkle:minimumSystemVersion" where !value.isEmpty: current?.minimumSystem = value
        default: break
        }
        text = ""
    }
}

/// Refuses any redirect that leaves HTTPS.
private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}
