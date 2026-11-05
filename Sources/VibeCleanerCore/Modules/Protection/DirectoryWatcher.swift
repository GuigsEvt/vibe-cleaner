import Foundation

/// Real-time monitor engine: watches the top level of a few folders with vnode dispatch sources
/// and reports files that appeared or changed, once they have been quiet for `latency`.
/// Partial downloads (`.download`, `.crdownload`, `.part`) are reported only when renamed to their final name.
public final class DirectoryWatcher: @unchecked Sendable {
    public let directories: [URL]
    private let latency: DispatchTimeInterval
    private let onChange: @Sendable ([URL]) -> Void
    private let queue = DispatchQueue(label: "vibecleaner.watcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var snapshots: [URL: [String: Date]] = [:]
    private var generation = 0

    static let partial: Set<String> = ["download", "crdownload", "part"]

    public init(directories: [URL], latency: DispatchTimeInterval = .seconds(2), onChange: @escaping @Sendable ([URL]) -> Void) {
        self.directories = directories
        self.latency = latency
        self.onChange = onChange
    }

    public func start() {
        queue.sync {
            guard sources.isEmpty else { return }
            for dir in directories {
                let fd = open(dir.path, O_EVTONLY)
                guard fd >= 0 else { continue }
                snapshots[dir] = Self.listing(dir)
                let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: queue)
                s.setEventHandler { [weak self] in self?.schedule() }
                s.setCancelHandler { close(fd) }
                s.resume()
                sources.append(s)
            }
        }
    }

    public func stop() {
        queue.sync {
            sources.forEach { $0.cancel() }
            sources = []
            generation += 1
        }
    }

    deinit { sources.forEach { $0.cancel() } }

    /// Debounce: a burst of events produces a single diff.
    private func schedule() {
        generation += 1
        let g = generation
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self, g == self.generation, !self.sources.isEmpty else { return }
            self.diff()
        }
    }

    private func diff() {
        var changed: [URL] = []
        for dir in directories where snapshots[dir] != nil {
            let now = Self.listing(dir)
            let before = snapshots[dir] ?? [:]
            for (name, date) in now where before[name] != date && !Self.partial.contains((name as NSString).pathExtension.lowercased()) {
                changed.append(dir.appendingPathComponent(name))
            }
            snapshots[dir] = now
        }
        if !changed.isEmpty { onChange(changed.sorted { $0.path < $1.path }) }
    }

    static func listing(_ dir: URL) -> [String: Date] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return Dictionary(urls.map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }) { a, _ in a }
    }
}
