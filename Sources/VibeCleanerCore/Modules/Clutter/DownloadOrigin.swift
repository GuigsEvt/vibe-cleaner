import Foundation

/// Where a downloaded file comes from, from the extended attributes browsers and apps set
/// (`kMDItemWhereFroms` for the URLs, `com.apple.quarantine` for the downloading app). Read-only, no Spotlight.
enum DownloadOrigin {
    static let whereFromsKey = "com.apple.metadata:kMDItemWhereFroms"
    static let quarantineKey = "com.apple.quarantine"

    static func xattr(_ url: URL, _ name: String) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }

    /// Source URL first, then the referrer, as Safari, Chrome, Firefox, Mail or Slack store them (binary plist array).
    static func whereFroms(_ url: URL) -> [String] {
        guard let data = xattr(url, whereFromsKey) else { return [] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }

    /// "0083;65f1c2a0;Safari;<uuid>" → "Safari".
    static func agent(_ url: URL) -> String? {
        guard let data = xattr(url, quarantineKey) else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let name = parts[2].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// (app, account): the downloading app, then the Slack workspace or the web site the file came from.
    static func source(_ url: URL) -> (app: String, account: String) {
        let hosts = whereFroms(url).compactMap { URL(string: $0)?.host?.lowercased() }
        var app = agent(url)
        if app == nil, hosts.contains(where: { $0 == "slack.com" || $0.hasSuffix(".slack.com") }) { app = "Slack" }
        if let workspace = hosts.first(where: { $0.hasSuffix(".slack.com") && !$0.hasPrefix("files.") && $0 != "app.slack.com" }) {
            return (app ?? "Slack", "Espace « \(workspace.dropLast(".slack.com".count)) »")
        }
        let site = hosts.first.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return (app ?? "Origine inconnue", site ?? "Adresse inconnue")
    }
}
