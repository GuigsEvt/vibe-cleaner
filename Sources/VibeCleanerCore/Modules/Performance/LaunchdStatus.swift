import Foundation

/// Loaded and disabled jobs of one launchd domain, parsed from `launchctl print <domain>` (read-only, no root).
struct LaunchdStatus: Sendable, Equatable {
    /// Label → PID, 0 when loaded but not running.
    var loaded: [String: Int] = [:]
    /// Labels whose override is "disabled" (`launchctl disable`).
    var disabled: Set<String> = []

    /// Parses the `services = { pid status label }` and `disabled services = { "label" => disabled }` blocks.
    static func parse(_ output: String) -> LaunchdStatus {
        var status = LaunchdStatus()
        var block = ""
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("= {") { block = String(line.dropLast(3)).trimmingCharacters(in: .whitespaces); continue }
            if line == "}" { block = ""; continue }
            switch block {
            case "services":
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if parts.count >= 3, let pid = Int(parts[0]) { status.loaded[parts[2...].joined(separator: " ")] = pid }
            case "disabled services":
                let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[1] == "disabled" { status.disabled.insert(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
            default:
                break
            }
        }
        return status
    }

    /// Reads the user's GUI domain and the system domain. Domains that cannot be read are left out.
    static func read(uid: uid_t = getuid()) -> [String: LaunchdStatus] {
        var out: [String: LaunchdStatus] = [:]
        for domain in ["gui/\(uid)", "system"] {
            let r = Shell.run("/bin/launchctl", ["print", domain])
            if r.ok { out[domain] = parse(r.stdout) }
        }
        return out
    }
}
