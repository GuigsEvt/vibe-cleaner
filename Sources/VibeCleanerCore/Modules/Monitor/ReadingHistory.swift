import Foundation

/// Fixed-size ring of the latest readings, oldest first. Appending past `capacity` drops the oldest one.
public struct ReadingHistory<Value: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Value] = []
    /// Index of the oldest reading once the ring is full.
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ value: Value) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    /// Readings in chronological order.
    public var values: [Value] { Array(storage[head...] + storage[..<head]) }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var last: Value? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// Recent readings behind the menu bar charts (CPU, memory, battery, network).
/// Fed with every sample: 2 s while the menu is open, 30 s otherwise, so the battery curve covers the session.
public struct MonitorHistory: Sendable {
    /// Two minutes at the foreground cadence.
    public static let liveCapacity = 60
    /// Two hours at the background cadence.
    public static let batteryCapacity = 240

    /// Percentages 0...100.
    public var cpuUser = ReadingHistory<Double>(capacity: liveCapacity)
    public var cpuSystem = ReadingHistory<Double>(capacity: liveCapacity)
    /// Used memory, percent of physical memory.
    public var memory = ReadingHistory<Double>(capacity: liveCapacity)
    /// Charge, percent.
    public var battery = ReadingHistory<Double>(capacity: batteryCapacity)
    /// Bytes per second.
    public var networkIn = ReadingHistory<Double>(capacity: liveCapacity)
    public var networkOut = ReadingHistory<Double>(capacity: liveCapacity)

    public init() {}

    public var cpuTotal: [Double] { zip(cpuUser.values, cpuSystem.values).map { min(100, $0 + $1) } }

    /// Records one sample. Unreadable parts (no memory figures, no battery) are skipped instead of charted as zero.
    public mutating func record(_ s: SystemSnapshot) {
        cpuUser.append(s.cpu.user)
        cpuSystem.append(s.cpu.system)
        if s.memory.total > 0 { memory.append(Double(s.memory.used) / Double(s.memory.total) * 100) }
        if let b = s.battery { battery.append(Double(b.percent)) }
        networkIn.append(max(0, s.network.bytesInPerSecond))
        networkOut.append(max(0, s.network.bytesOutPerSecond))
    }
}
