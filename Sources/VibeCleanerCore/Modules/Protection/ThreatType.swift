import CryptoKit
import Foundation

/// Threat families shown to the user. Guessed from a YARA rule or hash-list name;
/// heuristic findings are `suspicious`, which is not a verdict.
public enum ThreatType: String, Sendable, CaseIterable {
    case adware, backdoor, botnet, dropper, exploit, keylogger, miner, pua, ransomware, rootkit
    case spyware, stealer, trojan, virus, worm, suspicious, other

    public var label: String {
        switch self {
        case .adware: "Adware"
        case .backdoor: "Porte dérobée"
        case .botnet: "Botnet"
        case .dropper: "Dropper"
        case .exploit: "Exploit"
        case .keylogger: "Enregistreur de frappe"
        case .miner: "Mineur de cryptomonnaie"
        case .pua: "Application potentiellement indésirable"
        case .ransomware: "Rançongiciel"
        case .rootkit: "Rootkit"
        case .spyware: "Logiciel espion"
        case .stealer: "Voleur de données"
        case .trojan: "Cheval de Troie"
        case .virus: "Virus"
        case .worm: "Ver"
        case .suspicious: "Suspect"
        case .other: "Logiciel malveillant"
        }
    }

    /// Keywords checked in order against the tokens of a name ("XProtect_MACOS_ADLOAD_A" → MACOS, ADLOAD, A).
    /// Short keywords must match a whole token; longer ones may appear inside a token.
    static let keywords: [(String, ThreatType)] = [
        ("RANSOM", .ransomware), ("KERANGER", .ransomware), ("EVILQUEST", .ransomware), ("THIEFQUEST", .ransomware), ("LOCKBIT", .ransomware),
        ("STEALER", .stealer), ("STEAL", .stealer), ("ATOMIC", .stealer), ("AMOS", .stealer), ("CUCKOO", .stealer), ("POSEIDON", .stealer),
        ("BANSHEE", .stealer), ("REALST", .stealer), ("CTHULHU", .stealer), ("METASTEALER", .stealer),
        ("MINER", .miner), ("XMRIG", .miner), ("COINMINER", .miner),
        ("KEYLOG", .keylogger), ("KEYLOGGER", .keylogger),
        ("SPY", .spyware), ("SPYWARE", .spyware),
        ("BACKDOOR", .backdoor), ("RAT", .backdoor), ("RUSTBUCKET", .backdoor), ("KANDYKORN", .backdoor), ("GIMMICK", .backdoor),
        ("MACMA", .backdoor), ("OCEANLOTUS", .backdoor),
        ("BOTNET", .botnet), ("BOT", .botnet),
        ("ROOTKIT", .rootkit), ("EXPLOIT", .exploit), ("WORM", .worm), ("VIRUS", .virus),
        ("DROPPER", .dropper), ("DOWNLOADER", .dropper), ("LOADER", .dropper),
        ("TROJAN", .trojan), ("SHLAYER", .trojan), ("XCSSET", .trojan), ("DOK", .trojan),
        ("ADWARE", .adware), ("ADLOAD", .adware), ("PIRRIT", .adware), ("GENIEO", .adware), ("BUNDLORE", .adware),
        ("MAXOFFERDEAL", .adware), ("CROSSRIDER", .adware), ("VSEARCH", .adware), ("SEARCH", .adware),
        ("PUA", .pua), ("PUP", .pua), ("MACKEEPER", .pua),
    ]

    public static func classify(_ name: String) -> ThreatType {
        let tokens = name.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (k, type) in keywords where tokens.contains(where: { $0 == k || (k.count >= 5 && $0.contains(k)) }) { return type }
        return .other
    }
}

/// User-supplied SHA-256 list (`hashes.txt`): one hash per line, optionally followed by a name; `#` starts a comment.
/// Empty by default; Vibe Cleaner ships no hashes.
public struct HashList: Sendable {
    public var names: [String: String] = [:]
    public var isEmpty: Bool { names.isEmpty }

    public static func file(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/VibeCleaner/hashes.txt")
    }

    public init(text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = content.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let h = parts.first?.lowercased(), h.count == 64, h.allSatisfy(\.isHexDigit) else { continue }
            names[h] = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "Liste de hash locale"
        }
    }

    public init(home: URL) {
        self.init(text: (try? String(contentsOf: Self.file(home: home), encoding: .utf8)) ?? "")
    }

    /// Streams the file so large files are not loaded at once.
    static func sha256(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func match(_ url: URL) -> String? {
        guard !isEmpty, let h = Self.sha256(url) else { return nil }
        return names[h]
    }
}

/// Text of a threat notification. The file name is chosen by whoever dropped the file: control characters and line
/// breaks are removed, it is cut at 60 characters, and the detail (rule, path) is left to the Protection screen.
public enum ThreatNotice {
    public static func safeName(_ name: String, limit: Int = 60) -> String {
        let flat = String(String.UnicodeScalarView(name.unicodeScalars.map { s in
            s.value < 0x20 || (0x7F...0x9F).contains(s.value) || s == "\u{2028}" || s == "\u{2029}" ? " " : s
        })).trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    public static func body(_ threats: [ResultItem]) -> String {
        guard let first = threats.first else { return "" }
        return threats.count == 1
            ? "« \(safeName(first.name)) » a été détecté. Ouvrez Protection pour l'examiner."
            : "\(threats.count) éléments suspects, dont « \(safeName(first.name)) ». Ouvrez Protection pour les examiner."
    }
}
