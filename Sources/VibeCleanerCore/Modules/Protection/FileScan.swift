import Foundation

/// File-level detection: XProtect YARA rules, the local SHA-256 list, and the content of PKG installers
/// and ZIP archives expanded into a temporary folder (removed right after), with anti-bomb limits.
/// Tools run without a stderr pipe and under a time limit, so a flood of messages can't block the scan.
struct FileScan {
    struct Hit: Equatable {
        /// What gets quarantined: the file, or the archive it was found in.
        let path: String
        let rule: String
        let source: String
        var inner: String?
        var type: ThreatType { ThreatType.classify(rule) }
    }

    var yara: String?
    var rules: String
    var hashes: HashList
    var expandPKG: Bool
    var expandArchives: Bool

    static let containerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "sh", "command", "py", "js", "jar", "scpt", "dylib", "so", "bin"]
    static let maxHashedSize: Int64 = 64 << 20
    static let maxArchive = (files: 10_000, bytes: Int64(1) << 30, ratio: Int64(100))
    static let maxPKGSize: Int64 = 512 << 20

    /// Parses `yara` output lines "RuleName /path/to/file".
    static func parseYARA(_ output: String) -> [(rule: String, path: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> (rule: String, path: String)? in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
    }

    /// Parses the `zipinfo -t` summary: "N files, U bytes uncompressed, C bytes compressed: x%".
    static func zipTotals(_ output: String) -> (files: Int, uncompressed: Int64, compressed: Int64)? {
        let nums = output.split { !$0.isNumber }.compactMap { Int64($0) }
        guard nums.count >= 3, output.contains("uncompressed") else { return nil }
        return (Int(nums[0]), nums[1], nums[2])
    }

    static func zipIsSafe(_ t: (files: Int, uncompressed: Int64, compressed: Int64)) -> Bool {
        t.files <= maxArchive.files && t.uncompressed <= maxArchive.bytes && t.uncompressed <= max(t.compressed, 1) * maxArchive.ratio
    }

    /// Regular files worth hashing: executables and installer/script/archive types, up to 64 MB. Symlinks are skipped.
    static func candidates(under root: URL, maxLevel: Int = .max) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let accept: (URL) -> Bool = { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, Int64(v.fileSize ?? 0) <= maxHashedSize else { return false }
            return containerExtensions.contains(url.pathExtension.lowercased()) || fm.isExecutableFile(atPath: url.path)
        }
        guard isDir.boolValue else { return accept(root) ? [root] : [] }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            if e.level > maxLevel { e.skipDescendants(); continue }
            if accept(url) { out.append(url) }
        }
        return out
    }

    /// Every hit under `roots`, one per path; archives are expanded when found in `archiveRoots`.
    func scan(roots: [URL], archiveRoots: [URL], isCancelled: () -> Bool = { Task.isCancelled }) -> [Hit] {
        var hits: [String: Hit] = [:]
        func add(_ h: Hit) { if hits[h.path] == nil { hits[h.path] = h } }
        for h in direct(roots, isCancelled: isCancelled) { add(h) }
        if expandPKG || expandArchives {
            let archives = Set(archiveRoots.flatMap { Self.candidates(under: $0, maxLevel: 3) }.filter { a in
                let ext = a.pathExtension.lowercased()
                return (expandPKG && ["pkg", "mpkg"].contains(ext)) || (expandArchives && ext == "zip")
            })
            for a in archives.sorted(by: { $0.path < $1.path }) where hits[a.path] == nil && !isCancelled() {
                if let h = expand(a, isCancelled: isCancelled) { add(h) }
            }
        }
        return hits.values.sorted { $0.path < $1.path }
    }

    func direct(_ roots: [URL], isCancelled: () -> Bool) -> [Hit] {
        var out: [Hit] = []
        for root in roots where !isCancelled() {
            if yara != nil { out += yaraHits(root, isCancelled: isCancelled) }
            if !hashes.isEmpty {
                for f in Self.candidates(under: root) where !isCancelled() {
                    if let name = hashes.match(f) { out.append(Hit(path: f.path, rule: name, source: "Hash connu")) }
                }
            }
        }
        return out
    }

    /// yara prints "Rule path" lines with raw file names: a name holding a line break can forge a line naming any file.
    /// A hit is kept only for an existing regular file under `root`, and once yara run on that single file confirms it.
    func yaraHits(_ root: URL, isCancelled: () -> Bool) -> [Hit] {
        guard let yara, let output = Self.capture(yara, ["-r", "-w", "-N", rules, root.path], timeout: 3600, abort: isCancelled) else { return [] }
        let base = root.path
        return Self.parseYARA(output).filter { h in
            guard h.path == base || h.path.hasPrefix(base + "/"),
                  (try? FileManager.default.attributesOfItem(atPath: h.path))?[.type] as? FileAttributeType == .typeRegular,
                  let single = Self.capture(yara, ["-w", "-N", rules, h.path], timeout: 120, abort: isCancelled) else { return false }
            return Self.parseYARA(single).contains { $0.rule == h.rule && $0.path == h.path }
        }.map { Hit(path: $0.path, rule: $0.rule, source: "Règle") }
    }

    /// Thread-safe buffer for the output read in the background.
    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Runs a tool with stderr to /dev/null (a full stderr pipe would block it forever) and stdout read in the background
    /// when `capture`, else to /dev/null. Stops it when `abort` returns true (checked every 0.2 s) or after `timeout`.
    /// Returns the exit status and stdout, nil when stopped or not started.
    static func runWatched(_ exe: String, _ args: [String], capture: Bool, timeout: TimeInterval,
                           abort: () -> Bool) -> (status: Int32, stdout: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = capture ? pipe : FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let buffer = Buffer(), done = DispatchSemaphore(value: 0)
        if capture {
            let reader = pipe.fileHandleForReading
            DispatchQueue.global().async { buffer.set(reader.readDataToEndOfFile()); done.signal() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var stopped = false
        while p.isRunning {
            if abort() || Date() > deadline { p.terminate(); stopped = true; break }
            usleep(200_000)
        }
        // Polling, not `waitUntilExit`, which needs a run loop the scanning thread doesn't have. SIGKILL after 2 s.
        for i in 0..<100 where p.isRunning {
            if i == 40 { kill(p.processIdentifier, SIGKILL) }
            usleep(50_000)
        }
        if capture { done.wait() }
        return stopped ? nil : (p.terminationStatus, String(decoding: buffer.get(), as: UTF8.self))
    }

    static func capture(_ exe: String, _ args: [String], timeout: TimeInterval, abort: () -> Bool) -> String? {
        runWatched(exe, args, capture: true, timeout: timeout, abort: abort)?.stdout
    }

    /// Files and bytes under `dir`, stopping early past the archive limits.
    static func exceedsLimits(_ dir: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return false }
        var files = 0
        var bytes: Int64 = 0
        for case let u as URL in e {
            files += 1
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            bytes += Int64(max(v?.totalFileAllocatedSize ?? 0, v?.fileSize ?? 0))
            if files > maxArchive.files || bytes > maxArchive.bytes { return true }
        }
        return false
    }

    static let expandTimeout: TimeInterval = 120

    /// Expands one archive into a fresh temporary folder, scans it, and maps a hit back to the archive.
    /// The output is watched while the tool runs: past 10 000 files or 1 GB (a PKG payload can be a bomb too), it is stopped.
    func expand(_ archive: URL, isCancelled: () -> Bool) -> Hit? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("vc-expand-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let out = tmp.appendingPathComponent("x")
        var ticks = 0
        let abort: () -> Bool = {
            ticks += 1
            return isCancelled() || (ticks % 5 == 0 && Self.exceedsLimits(tmp))
        }
        switch archive.pathExtension.lowercased() {
        case "zip":
            guard let info = Self.capture("/usr/bin/zipinfo", ["-t", archive.path], timeout: 30, abort: isCancelled),
                  let t = Self.zipTotals(info), Self.zipIsSafe(t),
                  (try? fm.createDirectory(at: out, withIntermediateDirectories: true)) != nil,
                  // unzip exits 1 or 2 on a hostile entry (a link, "../") after extracting the rest: scan what is there.
                  Self.runWatched("/usr/bin/unzip", ["-qq", "-n", archive.path, "-d", out.path], capture: false,
                                  timeout: Self.expandTimeout, abort: abort) != nil else { return nil }
        default:
            guard FileSizer.size(of: archive) <= Self.maxPKGSize, (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
                  Self.runWatched("/usr/sbin/pkgutil", ["--expand-full", archive.path, out.path], capture: false,
                                  timeout: Self.expandTimeout, abort: abort) != nil,
                  !Self.exceedsLimits(tmp) else { return nil }
        }
        guard !Self.exceedsLimits(tmp), let h = direct([out], isCancelled: isCancelled).first else { return nil }
        let base = [out.path, out.resolvingSymlinksInPath().path].first { h.path.hasPrefix($0 + "/") }
        let inner = base.map { String(h.path.dropFirst($0.count + 1)) } ?? URL(fileURLWithPath: h.path).lastPathComponent
        return Hit(path: archive.path, rule: h.rule, source: h.source, inner: inner)
    }
}
