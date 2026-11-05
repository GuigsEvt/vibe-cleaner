import CoreWLAN
import Foundation

/// Connection type from the primary interface.
public enum NetworkKind: Sendable, Hashable {
    case offline, wifi, wired, vpn, other

    public init(interface: String?, isWiFi: Bool) {
        guard let name = interface else { self = .offline; return }
        if isWiFi { self = .wifi; return }
        if ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: name.hasPrefix) { self = .vpn; return }
        self = name.hasPrefix("en") ? .wired : .other
    }

    public var title: String {
        switch self {
        case .offline: "Hors ligne"
        case .wifi: "Wi-Fi"
        case .wired: "Filaire"
        case .vpn: "VPN"
        case .other: "Autre"
        }
    }
}

/// Wi-Fi security label and level (Open / Weak / Good / Strong).
public struct WiFiSecurity: Sendable, Hashable {
    public enum Level: Int, Sendable, Hashable, Comparable {
        case open, weak, good, strong, unknown
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public let label: String
    public let level: Level

    public init(label: String, level: Level) {
        self.label = label
        self.level = level
    }

    public init(_ s: CWSecurity) {
        switch s {
        case .none: self.init(label: "Ouvert", level: .open)
        case .OWE, .oweTransition: self.init(label: "Ouvert chiffré (OWE)", level: .open)
        case .WEP, .dynamicWEP: self.init(label: "WEP", level: .weak)
        case .wpaPersonal, .wpaPersonalMixed: self.init(label: "WPA Personnel", level: .weak)
        case .wpaEnterprise, .wpaEnterpriseMixed: self.init(label: "WPA Entreprise", level: .weak)
        case .wpa2Personal, .personal: self.init(label: "WPA2 Personnel", level: .good)
        case .wpa2Enterprise, .enterprise: self.init(label: "WPA2 Entreprise", level: .good)
        case .wpa3Transition: self.init(label: "WPA2/WPA3 Personnel", level: .good)
        case .wpa3Personal: self.init(label: "WPA3 Personnel", level: .strong)
        case .wpa3Enterprise: self.init(label: "WPA3 Entreprise", level: .strong)
        default: self.init(label: "Inconnue", level: .unknown)
        }
    }

    public var advice: String {
        switch level {
        case .open: "Ce réseau Wi-Fi est ouvert : vos données peuvent être lues par d'autres. Évitez d'y saisir des informations sensibles."
        case .weak: "Le chiffrement de ce réseau est ancien et facile à casser. Passez le routeur en WPA2 ou WPA3 si possible."
        case .good: "Ce réseau utilise un bon niveau de chiffrement."
        case .strong: "Ce réseau utilise le meilleur chiffrement disponible."
        case .unknown: "Le niveau de sécurité de ce réseau n'a pas pu être lu."
        }
    }
}

/// Result of Apple's `networkQuality` tool. Launched only when the user clicks "Tester le débit".
public struct SpeedTestResult: Sendable, Hashable {
    /// Megabits per second.
    public var download: Double
    public var upload: Double
    /// Milliseconds.
    public var rtt: Double?
    /// Round-trips per minute under load.
    public var responsiveness: Double?

    public init(download: Double, upload: Double, rtt: Double? = nil, responsiveness: Double? = nil) {
        self.download = download
        self.upload = upload
        self.rtt = rtt
        self.responsiveness = responsiveness
    }

    public static let tool = "/usr/bin/networkQuality"
    /// `-c` prints JSON, `-s` measures download and upload one after the other.
    public static let arguments = ["-c", "-s"]

    /// Parses `networkQuality -c` output (throughputs in bits per second).
    public static func parse(_ json: String) -> SpeedTestResult? {
        guard let start = json.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        guard let dl = num("dl_throughput"), let ul = num("ul_throughput") else { return nil }
        return SpeedTestResult(download: dl / 1e6, upload: ul / 1e6, rtt: num("base_rtt"),
                               responsiveness: num("responsiveness") ?? num("dl_responsiveness"))
    }

    /// Usages the download speed supports.
    public var goodFor: [String] {
        var out: [String] = []
        if download >= 1 { out += ["Messagerie", "Appels audio"] }
        if download >= 2 { out.append("Musique en streaming") }
        if download >= 5 { out.append("Appels vidéo") }
        if download >= 10, (rtt ?? .infinity) < 50 { out.append("Jeu en ligne") }
        if download >= 15 { out.append("Vidéo en streaming") }
        return out
    }

    public static func run() -> SpeedTestResult? {
        let r = Shell.run(tool, arguments)
        return r.ok ? parse(r.stdout) : nil
    }
}
