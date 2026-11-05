import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

/// Runs system tools without a shell (no string interpolation into sh -c).
public enum Shell {
    /// stdout and stderr are drained concurrently (a tool filling stderr cannot block on a full pipe).
    /// `timeout`: the tool is terminated (SIGTERM, then SIGKILL 2 s later) once it runs longer.
    /// `cancellable`: the same happens when the calling task is cancelled (Stop).
    /// `input` is written to the tool's standard input; otherwise stdin is /dev/null.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String] = [], input: Data? = nil,
                           timeout: TimeInterval? = nil, cancellable: Bool = true) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        do { try process.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        for (handle, box) in [(out.fileHandleForReading, outBox), (err.fileHandleForReading, errBox)] {
            group.enter()
            // Dedicated threads: a saturated dispatch pool (many callers blocked here) must never starve the readers.
            Thread.detachNewThread { box.set(handle.readDataToEndOfFile()); group.leave() }
        }
        if let input {
            let w = inPipe.fileHandleForWriting
            // A tool that exits without reading all its input must not SIGPIPE the whole app.
            _ = fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread { try? w.write(contentsOf: input); try? w.close() }
        }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var stopped: String?
        var killAt = Date.distantFuture
        while group.wait(timeout: .now() + 0.1) == .timedOut {
            if stopped == nil {
                if let deadline, Date() >= deadline { stopped = "délai dépassé (\(Int(timeout ?? 0)) s)" }
                else if cancellable && Task.isCancelled { stopped = "interrompu" }
                if stopped != nil { process.terminate(); killAt = Date().addingTimeInterval(2) }
            } else if process.isRunning {
                if Date() >= killAt { kill(process.processIdentifier, SIGKILL) }
            } else if Date() >= killAt {
                break // a grandchild still holds the pipes: give up on the rest of the output
            }
        }
        process.waitUntilExit()
        var stderr = String(decoding: errBox.get(), as: UTF8.self)
        if let stopped { stderr += (stderr.isEmpty ? "" : "\n") + stopped }
        return ShellResult(status: stopped != nil && process.terminationStatus == 0 ? -1 : process.terminationStatus,
                           stdout: String(decoding: outBox.get(), as: UTF8.self), stderr: stderr)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.withLock { data = d } }
    func get() -> Data { lock.withLock { data } }
}
