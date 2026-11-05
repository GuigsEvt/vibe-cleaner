import Foundation

/// Point-in-time view of the Mac for the menu bar and the health dashboard.
public struct SystemSnapshot: Sendable, Hashable {
    public var date: Date
    public var cpu: CPUUsage
    public var memory: MemoryUsage
    /// Startup volume; nil if it could not be read.
    public var disk: DiskUsage?
    /// nil on Macs without an internal battery.
    public var battery: BatteryInfo?
    public var network: NetworkUsage
    public var uptime: TimeInterval
    /// Size of `~/.Trash`; nil when unreadable (usually no Full Disk Access).
    public var trashSize: Int64?
    /// `ProcessInfo.thermalState`: the only public temperature signal (no SMC, no HID sensors).
    public var thermal: ThermalLevel

    public init(date: Date = Date(), cpu: CPUUsage = CPUUsage(), memory: MemoryUsage = MemoryUsage(), disk: DiskUsage? = nil,
                battery: BatteryInfo? = nil, network: NetworkUsage = NetworkUsage(), uptime: TimeInterval = 0, trashSize: Int64? = nil,
                thermal: ThermalLevel = .nominal) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.battery = battery
        self.network = network
        self.uptime = uptime
        self.trashSize = trashSize
        self.thermal = thermal
    }
}

public enum ThermalLevel: Int, Sendable, Hashable, Comparable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        default: self = .nominal
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .nominal: "Normale"
        case .fair: "Tiède"
        case .serious: "Élevée"
        case .critical: "Critique"
        }
    }

    public var detail: String {
        switch self {
        case .nominal: "Votre Mac fonctionne dans sa plage de température idéale."
        case .fair: "Votre Mac chauffe un peu, mais reste dans la normale."
        case .serious: "Votre Mac est chaud et ralentit pour se refroidir. Quittez les apps gourmandes."
        case .critical: "Votre Mac est bien trop chaud. Fermez les apps lourdes et laissez-le refroidir."
        }
    }
}

/// Percentages in 0...100 over all logical cores.
public struct CPUUsage: Sendable, Hashable {
    public var user: Double
    public var system: Double
    public var coreCount: Int
    public var total: Double { user + system }
    public var idle: Double { max(0, 100 - total) }

    public init(user: Double = 0, system: Double = 0, coreCount: Int = 0) {
        self.user = user
        self.system = system
        self.coreCount = coreCount
    }
}

public enum MemoryPressure: Int, Sendable, Hashable, Comparable {
    case normal, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Byte counts computed like Activity Monitor: used = app + wired + compressed.
public struct MemoryUsage: Sendable, Hashable {
    public var total: Int64
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    /// File-backed and purgeable pages the system can reclaim.
    public var cache: Int64
    public var pressure: MemoryPressure
    public var swapTotal: Int64
    public var swapUsed: Int64

    public var used: Int64 { app + wired + compressed }
    public var available: Int64 { max(0, total - used) }
    public var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }

    public init(total: Int64 = 0, app: Int64 = 0, wired: Int64 = 0, compressed: Int64 = 0, cache: Int64 = 0,
                pressure: MemoryPressure = .normal, swapTotal: Int64 = 0, swapUsed: Int64 = 0) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cache = cache
        self.pressure = pressure
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
    }
}

public struct DiskUsage: Sendable, Hashable {
    public var total: Int64
    /// Free space including purgeable (`volumeAvailableCapacityForImportantUsage`), the figure Finder shows.
    public var available: Int64
    /// Space macOS can reclaim on demand (snapshots, iCloud copies, caches), included in `available`.
    public var purgeable: Int64
    public var used: Int64 { max(0, total - available) }
    public var availableFraction: Double { total > 0 ? Double(available) / Double(total) : 0 }

    public init(total: Int64, available: Int64, purgeable: Int64 = 0) {
        self.total = total
        self.available = available
        self.purgeable = purgeable
    }
}

public enum BatteryHealthLevel: Sendable, Hashable {
    case perfect, normal, warning, critical, unknown
}

public struct BatteryInfo: Sendable, Hashable {
    public static let perfectHealthPercent = 95.0
    public static let normalHealthPercent = 80.0
    public static let warningHealthPercent = 60.0
    public static let hotTemperatureCelsius = 40.0

    /// Charge in 0...100.
    public var percent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var cycleCount: Int?
    /// Maximum capacity relative to design capacity, in percent.
    public var healthPercent: Double?
    /// macOS flagged the battery ("Service Recommended", "Check Battery"...).
    public var serviceRecommended: Bool
    public var temperatureCelsius: Double?
    /// Minutes to empty (on battery) or to full (charging); nil while macOS is calculating.
    public var minutesRemaining: Int?

    public var healthLevel: BatteryHealthLevel {
        if serviceRecommended { return .critical }
        guard let h = healthPercent else { return .unknown }
        switch h {
        case Self.perfectHealthPercent...: return .perfect
        case Self.normalHealthPercent...: return .normal
        case Self.warningHealthPercent...: return .warning
        default: return .critical
        }
    }

    public init(percent: Int, isCharging: Bool = false, isPluggedIn: Bool = false, cycleCount: Int? = nil, healthPercent: Double? = nil,
                serviceRecommended: Bool = false, temperatureCelsius: Double? = nil, minutesRemaining: Int? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.serviceRecommended = serviceRecommended
        self.temperatureCelsius = temperatureCelsius
        self.minutesRemaining = minutesRemaining
    }
}

public struct NetworkUsage: Sendable, Hashable {
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double
    /// Primary interface from SystemConfiguration (en0, utun3...); nil when offline.
    public var activeInterface: String?
    public var isWiFi: Bool
    /// SSID; nil without Location Services permission (never requested by the app).
    public var wifiName: String?
    public var wifiSecurity: WiFiSecurity?

    public init(bytesInPerSecond: Double = 0, bytesOutPerSecond: Double = 0, activeInterface: String? = nil,
                isWiFi: Bool = false, wifiName: String? = nil, wifiSecurity: WiFiSecurity? = nil) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
        self.activeInterface = activeInterface
        self.isWiFi = isWiFi
        self.wifiName = wifiName
        self.wifiSecurity = wifiSecurity
    }

    public var kind: NetworkKind { NetworkKind(interface: activeInterface, isWiFi: isWiFi) }
}

public struct ProcessUsage: Identifiable, Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var path: String?
    /// Share of one core, like Activity Monitor (can exceed 100).
    public var cpuPercent: Double
    /// Physical footprint in bytes.
    public var memory: Int64
    /// Command line of an interpreter (python, node…), to tell its scripts apart; empty for other processes.
    /// Only readable for the user's own processes, so a non-empty list also means the user may stop it.
    public var arguments: [String] = []
    /// Processes of a script running several times ("Python : train.py" ×4), highest CPU first; empty for a single one.
    public var members: [ProcessUsage] = []
    /// Start of the process (µs since 1970, `proc_bsdinfo`): a pid is reused once its process ends, so it is checked
    /// again before signalling. nil when unreadable.
    public var startTime: UInt64?
    /// Every pid the line stands for.
    public var pids: [Int32] { members.isEmpty ? [pid] : members.map(\.pid) }
    public var id: Int32 { pid }

    /// Part of macOS: no executable path readable, or one under the system folders.
    public var isSystem: Bool {
        guard let path else { return true }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    public init(pid: Int32, name: String, path: String? = nil, cpuPercent: Double, memory: Int64) {
        self.pid = pid
        self.name = name
        self.path = path
        self.cpuPercent = cpuPercent
        self.memory = memory
    }
}
