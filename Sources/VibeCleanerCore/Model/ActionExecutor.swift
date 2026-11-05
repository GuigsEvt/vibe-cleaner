import Foundation

public struct ExecutionReport: Sendable {
    public var processed: [String] = []
    public var freedBytes: Int64 = 0
    public var failures: [(id: String, reason: String)] = []
    public var log: [String] = []
    /// Admin items handed to an active `AdminCollector`: neither processed nor failed until it is flushed.
    public var deferred: [String] = []

    public init() {}

    public var outcome: Outcome {
        if failures.isEmpty { return processed.isEmpty ? .empty : .success }
        return processed.isEmpty ? .failure : .partial
    }

    public enum Outcome: Sendable { case success, partial, failure, empty }

    /// Adds `other` (e.g. the flushed admin outcome) and clears the ids it settles from `deferred`.
    public mutating func merge(_ other: ExecutionReport) {
        processed += other.processed
        freedBytes += other.freedBytes
        failures += other.failures
        log += other.log
        let settled = Set(other.processed + other.failures.map(\.id))
        deferred = deferred.filter { !settled.contains($0) } + other.deferred
    }
}

/// Per-item progress and Stop for `ActionExecutor.run`, without changing module signatures:
/// the app binds `onItem` around `module.execute`, and cancelling the executing task stops the run.
public enum ExecutionProgress {
    /// Called from the executing task as each item starts.
    @TaskLocal public static var onItem: (@Sendable (ResultItem) -> Void)?
    public static let stoppedReason = "non traité : interrompu par le bouton Arrêter"
}

/// Executes the actions of selected items. All root work goes into a single administrator prompt.
/// Checks `Task.isCancelled` before each item and before the administrator batch.
public struct ActionExecutor: Sendable {
    public static let defaultPrompt = "Vibe Cleaner a besoin des droits administrateur pour terminer."

    /// When bound, admin work of every `run` is collected instead of run, so that several modules
    /// (Vibe Check) share one prompt: see `AdminCollector.flush`.
    @TaskLocal public static var adminCollector: AdminCollector?

    public var remover: SafeRemover
    public var adminPrompt: String
    /// a deletion whose target was modified after the scan is skipped and reported. Only for modules whose
    /// `ResultItem.date` is the scanned modification date (Nettoyage); elsewhere it can be a last-used or added date.
    public var revalidatesModificationDate: Bool

    public init(remover: SafeRemover = SafeRemover(), adminPrompt: String = ActionExecutor.defaultPrompt,
                revalidatesModificationDate: Bool = false) {
        self.remover = remover
        self.adminPrompt = adminPrompt
        self.revalidatesModificationDate = revalidatesModificationDate
    }

    public static let modifiedSinceScan = "modifié depuis l'analyse"

    /// The file's modification date now is more than a second after the one the scan saw (lstat: no cached value, no link followed).
    static func isModifiedSinceScan(_ item: ResultItem, url: URL) -> Bool {
        guard let scanned = item.date,
              let now = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(scanned) > 1
    }

    public func run(_ items: [ResultItem], custom: (ResultItem, String) throws -> Void = { _, k in
        throw RemovalError.failed(k, "action non prise en charge")
    }) -> ExecutionReport {
        var report = ExecutionReport()
        var adminBatch: [(ResultItem, [String])] = []

        for (i, item) in items.enumerated() {
            if Task.isCancelled {
                for rest in items[i...] where rest.action != .none { report.failures.append((rest.id, ExecutionProgress.stoppedReason)) }
                break
            }
            ExecutionProgress.onItem?(item)
            switch item.action {
            case .delete(let url, let mode, let admin):
                if revalidatesModificationDate && Self.isModifiedSinceScan(item, url: url) {
                    report.failures.append((item.id, Self.modifiedSinceScan))
                } else if admin {
                    do {
                        try remover.check(url)
                        adminBatch.append((item, try Self.adminDeleteCommand(url, mode: mode)))
                    } catch {
                        report.failures.append((item.id, error.localizedDescription))
                    }
                } else {
                    let r = remover.remove([url], mode: mode)
                    if let f = r.failures.first {
                        report.failures.append((item.id, f.1))
                    } else {
                        report.processed.append(item.id)
                        report.freedBytes += item.size
                        report.log.append("\(mode == .trash ? "Corbeille" : "Supprimé") : \(url.path)")
                    }
                }
            case .command(let exe, let args, let admin):
                if admin {
                    // A root command that carries a scanned path is revalidated like a deletion (exclusions added since the scan).
                    if let url = item.url {
                        do { try remover.check(url) } catch { report.failures.append((item.id, error.localizedDescription)); continue }
                    }
                    adminBatch.append((item, [exe] + args)); continue
                }
                if remover.dryRun { report.processed.append(item.id); continue }
                let r = Shell.run(exe, args)
                if r.ok {
                    report.processed.append(item.id)
                    report.log.append("Exécuté : \(([exe] + args).joined(separator: " "))")
                } else {
                    report.failures.append((item.id, r.stderr.isEmpty ? "code \(r.status)" : r.stderr))
                }
            case .custom(let key):
                do {
                    if !remover.dryRun { try custom(item, key) }
                    report.processed.append(item.id)
                    report.freedBytes += item.size
                    report.log.append("\(item.name) : \(key)")
                } catch {
                    report.failures.append((item.id, error.localizedDescription))
                }
            case .none:
                break
            }
        }

        guard !adminBatch.isEmpty else { return report }
        if let collector = Self.adminCollector {
            collector.add(adminBatch)
            report.deferred += adminBatch.map(\.0.id)
            return report
        }
        report.merge(Self.runBatch(adminBatch, dryRun: remover.dryRun, prompt: adminPrompt))
        return report
    }

    /// The admin phase: one prompt for every command, nothing run in simulation or after Stop.
    static func runBatch(_ batch: [(ResultItem, [String])], dryRun: Bool, prompt: String) -> ExecutionReport {
        var report = ExecutionReport()
        guard !batch.isEmpty else { return report }
        if Task.isCancelled {
            for (item, _) in batch { report.failures.append((item.id, ExecutionProgress.stoppedReason)) }
            return report
        }
        if dryRun {
            for (item, _) in batch { report.processed.append(item.id); report.freedBytes += item.size }
            return report
        }
        switch Shell.runAdminBatch(batch.map(\.1), prompt: prompt) {
        case .failure(let err):
            for (item, _) in batch { report.failures.append((item.id, err.message)) }
        case .success(let failedIndexes):
            for (i, (item, cmd)) in batch.enumerated() {
                if failedIndexes.contains(i) {
                    report.failures.append((item.id, "échec de : \(Self.describe(cmd))"))
                } else {
                    report.processed.append(item.id)
                    report.freedBytes += item.size
                    report.log.append("Admin : \(Self.describe(cmd))")
                }
            }
        }
        return report
    }

    /// Readable form of an admin command: the fixed scripts are shown by their arguments only.
    static func describe(_ cmd: [String]) -> String {
        cmd.count > 3 && cmd[0] == "/bin/sh" && cmd[1] == "-c" ? "sh " + cmd.dropFirst(3).joined(separator: " ") : cmd.joined(separator: " ")
    }
}

/// Collects the admin commands of several `ActionExecutor.run` calls (bound through `ActionExecutor.$adminCollector`)
/// and runs them behind a single prompt.
public final class AdminCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(ResultItem, [String])] = []
    public let prompt: String

    public init(prompt: String = ActionExecutor.defaultPrompt) { self.prompt = prompt }

    public var isEmpty: Bool { lock.withLock { pending.isEmpty } }
    public var ids: [String] { lock.withLock { pending.map(\.0.id) } }

    func add(_ batch: [(ResultItem, [String])]) { lock.withLock { pending += batch } }

    /// Runs every collected command (one prompt, none in simulation, none after Stop) and empties the collector.
    /// Split the outcome per module with `Outcome.report(for:)`.
    public func flush(dryRun: Bool) async -> Outcome {
        let batch = lock.withLock { () -> [(ResultItem, [String])] in defer { pending = [] }; return pending }
        let report = ActionExecutor.runBatch(batch, dryRun: dryRun, prompt: prompt)
        return Outcome(report: report, sizes: Dictionary(batch.map { ($0.0.id, $0.0.size) }, uniquingKeysWith: { a, _ in a }))
    }

    public struct Outcome: Sendable {
        /// Every collected item.
        public let report: ExecutionReport
        let sizes: [String: Int64]

        /// The part of the outcome that concerns `ids` (the items one module was given).
        public func report(for ids: Set<String>) -> ExecutionReport {
            var r = ExecutionReport()
            r.processed = report.processed.filter(ids.contains)
            r.failures = report.failures.filter { ids.contains($0.id) }
            r.freedBytes = r.processed.reduce(0) { $0 + (sizes[$1] ?? 0) }
            r.log = r.processed.isEmpty ? [] : ["Admin : \(r.processed.count) élément(s)"]
            return r
        }
    }
}

extension ActionExecutor {
    /// Root-owned items set aside by Vibe Cleaner (`.trash` mode). Every ancestor is root-owned and not writable by
    /// the user, so a root `mv` there cannot be redirected through a symlink the user planted (as in ~/.Trash).
    /// Offered for permanent removal under Nettoyage › Corbeilles.
    public static let rootTrash = "/Library/Application Support/VibeCleaner/Corbeille"

    /// $1 path, $2 physical parent expected. Refuses to act when a parent was replaced by a symlink since the check.
    static let parentGuard = #"cd -P -- "$(/usr/bin/dirname -- "$1")" 2>/dev/null && [ "$(pwd -P)" = "$2" ] || exit 3; p="./${1##*/}""#
    /// $1 path, $3 holding area: a fresh root-made folder per item, and a real failure when nothing moved.
    static let moveToRootTrash = #"""
    [ -e "$p" ] || [ -L "$p" ] || exit 4
    /bin/mkdir -p -m 755 -- "$3" || exit 5
    [ -d "$3" ] && [ ! -L "$3" ] && [ "$(cd -P -- "$3" && pwd -P)" = "$3" ] || exit 5
    d=$(/usr/bin/mktemp -d "$3/XXXXXXXX") || exit 5
    /bin/chmod 755 "$d"
    /bin/mv -- "$p" "$d/" && [ ! -e "$p" ] && [ ! -L "$p" ]
    """#
    static let trashScript = parentGuard + "\n" + moveToRootTrash
    static let deleteScript = parentGuard + "\n" + #"/bin/rm -rf -- "$p" && [ ! -e "$p" ] && [ ! -L "$p" ]"#

    /// Physical parent of `url`: realpath, which may only add the /private prefix (/tmp, /var). Nil when a parent
    /// is any other symlink: root never works through a link that could have been swapped.
    static func physicalParent(_ url: URL) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let real = Junk.realPath(parent)
        return real == parent || real == "/private" + parent ? real : nil
    }

    /// Root-owned items honour the removal mode: `.trash` moves them into `rootTrash`, only `.permanent` deletes.
    static func adminDeleteCommand(_ url: URL, mode: RemovalMode, rootTrash: String = rootTrash) throws -> [String] {
        let path = url.path
        guard let parent = physicalParent(url) else {
            throw RemovalError.failed(path, "un dossier parent est un lien symbolique")
        }
        switch mode {
        case .permanent: return ["/bin/sh", "-c", deleteScript, "sh", path, parent]
        case .trash: return ["/bin/sh", "-c", trashScript, "sh", path, parent, rootTrash]
        }
    }
}

extension Shell {

    /// Runs several commands as root behind one prompt. Returns indexes of commands that failed,
    /// or `.failure` when the prompt was cancelled or could not run.
    /// The AppleScript goes through stdin (no ARG_MAX on osascript's arguments) and the commands are split into
    /// chunks run one after the other in the same process, which keeps the authorization.
    public static func runAdminBatch(_ commands: [[String]], prompt: String) -> Result<Set<Int>, BatchFailure> {
        let script = adminAppleScript(commands, prompt: prompt)
        let r = run("/usr/bin/osascript", [], input: Data(script.utf8), cancellable: false)
        guard r.ok else { return .failure(BatchFailure(message: r.stderr.contains("-128") ? "Autorisation annulée" : r.stderr)) }
        return parseBatchOutput(r.stdout, count: commands.count)
    }

    /// VCFAIL:<i> for each failed command; VCABORT:<first>:<error> when a chunk could not run (prompt cancelled…).
    static func parseBatchOutput(_ output: String, count: Int) -> Result<Set<Int>, BatchFailure> {
        var failed = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("VCFAIL:"), let i = Int(line.dropFirst(7)) { failed.insert(i) }
            if line.hasPrefix("VCABORT:") {
                let parts = line.dropFirst(8).split(separator: ":")
                let first = parts.first.flatMap { Int($0) } ?? 0
                if first == 0 {
                    return .failure(BatchFailure(message: parts.dropFirst().first == "-128" ? "Autorisation annulée" : "lot administrateur interrompu"))
                }
                failed.formUnion(first..<count)
            }
        }
        return .success(failed)
    }

    /// Chunks of at most `maxCommands` commands and about `maxBytes` of shell text (ARG_MAX is 1 MiB for `sh -c`).
    static func adminAppleScript(_ commands: [[String]], prompt: String, maxCommands: Int = 200, maxBytes: Int = 200_000) -> String {
        var chunks: [(start: Int, script: String)] = []
        var start = 0, lines: [String] = [], bytes = 0
        for (i, cmd) in commands.enumerated() {
            let line = adminBatchLine(cmd, index: i)
            if !lines.isEmpty && (lines.count >= maxCommands || bytes + line.utf8.count > maxBytes) {
                chunks.append((start, lines.joined(separator: "; "))); start = i; lines = []; bytes = 0
            }
            lines.append(line); bytes += line.utf8.count + 2
        }
        if !lines.isEmpty { chunks.append((start, lines.joined(separator: "; "))) }
        var out = ["set out to \"\""]
        for c in chunks {
            out += ["try",
                    "set out to out & (do shell script \(appleScriptString(c.script)) with prompt \(appleScriptString(prompt)) with administrator privileges) & linefeed",
                    "on error errMsg number errNum",
                    "return out & \"VCABORT:\(c.start):\" & errNum",
                    "end try"]
        }
        out.append("return out")
        return out.joined(separator: "\n")
    }

    /// The `sh` script of the batch: every argument single-quoted, each failing command echoes `VCFAIL:<index>`.
    static func adminBatchScript(_ commands: [[String]]) -> String {
        commands.enumerated().map { adminBatchLine($1, index: $0) }.joined(separator: "; ")
    }

    static func adminBatchLine(_ cmd: [String], index: Int) -> String {
        cmd.map(shellQuote).joined(separator: " ") + " >/dev/null 2>&1 || echo VCFAIL:\(index)"
    }

    public struct BatchFailure: Error, Sendable { public let message: String }
}
