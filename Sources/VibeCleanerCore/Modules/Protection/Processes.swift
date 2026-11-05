import Darwin
import Foundation

/// Running processes, listed with libproc. A process is suspicious when its
/// executable has a broken signature, or runs unsigned / un-notarized from a hidden, temporary or download folder.
enum Processes {
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/", "/Applications/"]

    static func all() -> [(pid: Int32, path: String)] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(max(count, 0))).compactMap { pid in
            guard pid > 0 else { return nil }
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            return len > 0 ? (pid, String(decoding: buf.prefix(Int(len)), as: UTF8.self)) : nil
        }
    }

    /// Processes whose executable is `url` or lies inside it (an app bundle).
    static func pids(runningFrom url: URL, in list: [(pid: Int32, path: String)]) -> [Int32] {
        let p = url.standardizedFileURL.path
        return list.filter { $0.path == p || $0.path.hasPrefix(p + "/") }.map(\.pid)
    }

    /// SIGTERM, then SIGKILL for whatever is still alive after two seconds. Execution only, never during a scan.
    @discardableResult
    static func terminate(runningFrom url: URL) -> Int {
        let targets = pids(runningFrom: url, in: all()).filter { $0 != getpid() }
        guard !targets.isEmpty else { return 0 }
        for pid in targets { kill(pid, SIGTERM) }
        for _ in 0..<20 where targets.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return targets.count
    }

    /// The bundle to quarantine for an executable: its `.app` when it runs from one.
    static func removalTarget(_ exe: String) -> URL {
        if let r = exe.range(of: ".app/Contents/MacOS/") { return URL(fileURLWithPath: String(exe[..<r.lowerBound]) + ".app") }
        return URL(fileURLWithPath: exe)
    }

    /// `blocked`: folders whose files are never opened (no signature check, no size) because that would show a
    /// permission prompt without Full Disk Access.
    static func group(_ list: [(pid: Int32, path: String)], context: ModuleContext, excludedTeamIDs: Set<String>, blocked: [String] = [],
                      check: (URL) -> SignatureInfo = { CodeSignature.check($0, validateResources: false) }) -> ResultGroup {
        let own = Bundle.main.executablePath
        let downloads = context.home.appendingPathComponent("Downloads").path + "/"
        var byPath: [String: [Int32]] = [:]
        for p in list where p.path != own && !systemPrefixes.contains(where: p.path.hasPrefix) { byPath[p.path, default: []].append(p.pid) }
        var items: [ResultItem] = []
        for (path, pids) in byPath.sorted(by: { $0.key < $1.key }) {
            let exe = URL(fileURLWithPath: path)
            let target = removalTarget(path)
            guard !FullDiskAccess.isUnder(path, blocked), !context.isExcluded(target) else { continue }
            let sig = check(exe)
            if let t = sig.teamID, excludedTeamIDs.contains(t) { continue }
            let risky = ProtectionModule.isSuspiciousLocation(exe, home: context.home) || ProtectionModule.isHiddenHomeLocation(exe, home: context.home)
                || path.hasPrefix(downloads)
            let reason: String
            switch sig.status {
            case .invalid: reason = "Signature invalide"
            case .unsigned:
                guard risky else { continue }
                reason = "Non signé, emplacement suspect"
            case .valid:
                guard risky && !sig.isApple && !sig.isNotarized else { continue }
                reason = "Non notarisé, emplacement suspect"
            }
            items.append(ResultItem(id: "prot.process.\(path)", name: exe.lastPathComponent,
                                    detail: "\(ThreatType.suspicious.label) · \(reason) — PID \(pids.map(String.init).joined(separator: ", ")) — \(path)",
                                    url: target, size: FileSizer.size(of: target), symbol: "cpu",
                                    action: .custom("quarantine-file"), autoSelect: false))
        }
        return ResultGroup(id: "prot.processes", title: "Processus suspects en cours",
                           subtitle: "Le processus est arrêté avant que son programme parte en quarantaine", symbol: "cpu", items: items)
    }
}
