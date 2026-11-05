import Darwin

/// "Arrêter" on a script of the menu panel: a polite SIGTERM, like Ctrl-C or `kill <pid>` in a terminal,
/// which lets the script clean up. Only the user's own processes; never this app.
public enum ProcessStopper {
    /// Stoppable: an interpreter process whose command line could be read (so the user's own), not this app.
    public static func canStop(_ p: ProcessUsage, ownPID: Int32 = getpid()) -> Bool {
        !p.arguments.isEmpty && !p.pids.contains(ownPID)
    }

    /// Sends SIGTERM to each process still owned by the user and still the one sampled (same start time: the pid
    /// was not reused since); returns how many received it.
    public static func stop(_ processes: [ProcessUsage], ownPID: Int32 = getpid()) -> Int {
        processes.filter { $0.pid > 1 && $0.pid != ownPID && isSame($0.pid, startedAt: $0.startTime) && kill($0.pid, SIGTERM) == 0 }.count
    }

    /// `pid` belongs to `uid` and started at `start`.
    static func isSame(_ pid: Int32, startedAt start: UInt64?, uid: uid_t = getuid()) -> Bool {
        guard let start, let info = info(pid) else { return false }
        return info.pbi_uid == uid && startTime(info) == start
    }

    /// Start of a process in µs since 1970, nil when it is gone or unreadable.
    static func startTime(_ pid: Int32) -> UInt64? { info(pid).map(startTime) }

    static func startTime(_ info: proc_bsdinfo) -> UInt64 { info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}
