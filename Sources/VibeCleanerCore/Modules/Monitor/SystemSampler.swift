import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration
import Synchronization

/// Reads system metrics. Keeps the previous sample so CPU and network figures are rates, not totals.
/// Call `sample()` periodically (2 s in the foreground, 30 s in the background).
public final class SystemSampler: Sendable {
    public let home: URL
    /// Minimum delay between two `~/.Trash` size computations (the walk is the only costly read).
    public let trashRefreshInterval: TimeInterval

    private struct State {
        var cpuTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
        var netCounters: [String: (inBytes: UInt32, outBytes: UInt32)] = [:]
        var netTime: TimeInterval = 0
        var trash: (size: Int64?, time: TimeInterval)?
        var procTimes: [Int32: UInt64] = [:]
        var procTime: TimeInterval = 0
    }

    private let state = Mutex(State())
    private let host = mach_host_self()

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), trashRefreshInterval: TimeInterval = 60) {
        self.home = home
        self.trashRefreshInterval = trashRefreshInterval
    }

    /// The next sample measures the Trash again instead of reusing the last size, e.g. when the panel opens.
    public func remeasureTrash() { state.withLock { $0.trash = nil } }

    public func sample() -> SystemSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let ticks = Self.cpuTicks(host)
        let counters = Self.interfaceCounters()

        let (cpu, network, trashState) = state.withLock { s -> (CPUUsage, (Double, Double), (Int64?, TimeInterval)?) in
            var cpu = CPUUsage(coreCount: ProcessInfo.processInfo.activeProcessorCount)
            if let t = ticks {
                let p = s.cpuTicks ?? (0, 0, 0, 0)
                let user = Double(t.user &- p.user) + Double(t.nice &- p.nice)
                let system = Double(t.system &- p.system)
                let all = user + system + Double(t.idle &- p.idle)
                if all > 0 { cpu.user = user / all * 100; cpu.system = system / all * 100 }
                s.cpuTicks = t
            }
            var rates = (0.0, 0.0)
            let dt = now - s.netTime
            if !s.netCounters.isEmpty, dt > 0 {
                var dIn: UInt64 = 0, dOut: UInt64 = 0
                for (name, c) in counters {
                    guard let p = s.netCounters[name] else { continue }
                    dIn += UInt64(c.inBytes &- p.inBytes)   // 32-bit kernel counters wrap
                    dOut += UInt64(c.outBytes &- p.outBytes)
                }
                rates = (Double(dIn) / dt, Double(dOut) / dt)
            }
            s.netCounters = counters
            s.netTime = now
            return (cpu, rates, s.trash)
        }

        var trashSize = trashState?.0
        if trashState == nil || now - trashState!.1 >= trashRefreshInterval {
            trashSize = Self.trashSize(home: home)
            state.withLock { $0.trash = (trashSize, now) }
        }

        let primary = Self.primaryInterface()
        let wifi = CWWiFiClient.shared().interface()
        let isWiFi = primary != nil && wifi?.interfaceName == primary
        return SystemSnapshot(
            cpu: cpu,
            memory: Self.memory(host),
            disk: Self.disk(),
            battery: Self.battery(),
            network: NetworkUsage(bytesInPerSecond: network.0, bytesOutPerSecond: network.1, activeInterface: primary,
                                  isWiFi: isWiFi, wifiName: isWiFi ? wifi?.ssid() : nil,
                                  wifiSecurity: isWiFi ? wifi.map { WiFiSecurity($0.security()) } : nil),
            uptime: Self.uptime(),
            trashSize: trashSize,
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState)
        )
    }

    /// Most demanding processes of the current user (other users' processes are not readable without root).
    /// CPU is measured since the previous call; the first call blocks ~250 ms to take two samples.
    /// Hungriest processes. With `groupByApp`, an app's helpers count in the app itself (as Activity Monitor groups them),
    /// so every app line can be quit as a whole.
    public func topProcesses(limit: Int, by sort: ProcessSort = .cpu, groupByApp: Bool = false) -> [ProcessUsage] {
        var (previous, previousTime) = state.withLock { ($0.procTimes, $0.procTime) }
        var now = ProcessInfo.processInfo.systemUptime
        if previous.isEmpty || now - previousTime > 60 {
            previous = Self.processes().reduce(into: [:]) { $0[$1.pid] = $1.cpuNanos }
            previousTime = now
            Thread.sleep(forTimeInterval: 0.25)
            now = ProcessInfo.processInfo.systemUptime
        }
        let current = Self.processes()
        state.withLock { s in
            s.procTimes = current.reduce(into: [:]) { $0[$1.pid] = $1.cpuNanos }
            s.procTime = now
        }
        let wallNanos = max(1, (now - previousTime) * 1e9)
        let each = current.map { p -> ProcessUsage in
            let delta = previous[p.pid].map { p.cpuNanos >= $0 ? p.cpuNanos - $0 : 0 } ?? 0
            var u = ProcessUsage(pid: p.pid, name: Self.displayName(p.name, path: p.path), path: p.path, cpuPercent: Double(delta) / wallNanos * 100, memory: p.memory)
            u.startTime = p.start
            if Self.isInterpreter(p.name), let args = Self.arguments(pid: p.pid) {
                u.arguments = args
                u.name = Self.interpreterLabel(p.name) + (Self.script(args).map { " : \($0)" } ?? "")
            }
            return u
        }
        let usages = groupByApp ? Self.groupedScripts(Self.groupedByApp(each)) : each
        let sorted = switch sort {
        case .cpu: usages.sorted { ($0.cpuPercent, $0.memory) > ($1.cpuPercent, $1.memory) }
        case .memory: usages.sorted { $0.memory > $1.memory }
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    public enum ProcessSort: Sendable { case cpu, memory }

    /// Tools installed as ".../<tool>/versions/2.1.296" run under their version number: show "<tool> 2.1.296".
    static func displayName(_ name: String, path: String?) -> String {
        guard !name.isEmpty, name.allSatisfy({ $0.isNumber || $0 == "." }), let path else { return name }
        let dirs = (path as NSString).pathComponents.dropLast()
        let tool = dirs.last == "versions" ? dirs.dropLast().last : dirs.last
        return tool.map { "\($0) \(name)" } ?? name
    }

    /// Interpreters whose name says nothing (all "Python"): their script is read from the command line.
    static func isInterpreter(_ name: String) -> Bool {
        name.range(of: #"^(python|ruby|perl|php|node|bun|deno|java)[0-9.]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Python" for python3.12 or the framework's Python, "Node" for node…
    static func interpreterLabel(_ name: String) -> String {
        let family = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
        return family == "php" ? "PHP" : family.prefix(1).uppercased() + family.dropFirst()
    }

    /// One line per script: the processes of an interpreter running the same script (workers of a training,
    /// a server's children) add up, and the line keeps them as `members` to show and stop one by one.
    static func groupedScripts(_ usages: [ProcessUsage]) -> [ProcessUsage] {
        var scripts: [String: [ProcessUsage]] = [:]
        var others: [ProcessUsage] = []
        for u in usages {
            if u.arguments.isEmpty { others.append(u) } else { scripts[u.name, default: []].append(u) }
        }
        let lines = scripts.values.map { list -> ProcessUsage in
            guard list.count > 1 else { return list[0] }
            let sorted = list.sorted { ($0.cpuPercent, $0.memory) > ($1.cpuPercent, $1.memory) }
            var line = ProcessUsage(pid: sorted[0].pid, name: sorted[0].name, path: sorted[0].path,
                                    cpuPercent: list.reduce(0) { $0 + $1.cpuPercent }, memory: list.reduce(0) { $0 + $1.memory })
            line.arguments = sorted[0].arguments
            line.startTime = sorted[0].startTime
            line.members = sorted
            return line
        }
        return others + lines
    }

    /// What an interpreter runs: the script's file name, "-m module", or "-c" for inline code; nil for a bare REPL.
    public static func script(_ args: [String]) -> String? {
        var rest = args.dropFirst()[...]
        while let a = rest.first {
            rest = rest.dropFirst()
            if a == "-m", let module = rest.first { return "-m \(module)" }
            if a == "-c" || a == "-e" { return a }
            // Options taking a value: skip it too.
            if ["-W", "-X", "-r", "--require", "--import", "-cp", "-classpath", "-jar"].contains(a) {
                if a == "-jar", let jar = rest.first { return (jar as NSString).lastPathComponent }
                rest = rest.dropFirst()
                continue
            }
            if a.hasPrefix("-") { continue }
            return (a as NSString).lastPathComponent
        }
        return nil
    }

    /// Command line of a process of the same user (`KERN_PROCARGS2`, read-only); nil when not allowed.
    static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard Darwin.sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard Darwin.sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc, the executable path, NUL padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Outermost `.app` bundle of an executable path ("/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/…"
    /// → "/Applications/Claude.app"); nil outside any app bundle. Chrome runs its main process from a temporary
    /// code-signing copy named "Google Chrome.app.bundle": that counts as "Google Chrome.app" too.
    static func appBundle(of path: String) -> String? {
        // The first ".app/" is the outermost bundle; nested helper apps sit deeper.
        let hits = [".app/", ".app.bundle/"].compactMap { path.range(of: $0) }
        guard let range = hits.min(by: { $0.lowerBound < $1.lowerBound }) else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Merges the processes of each app into one line named after the app: CPU and memory add up, the pid is
    /// the app's main process when it is running (its executable sits right in `Contents/MacOS`).
    /// Apps are matched by bundle name, so a temporary copy joins the installed app, whose path is kept.
    static func groupedByApp(_ usages: [ProcessUsage]) -> [ProcessUsage] {
        var apps: [String: [(bundle: String, usage: ProcessUsage)]] = [:]
        var loose: [ProcessUsage] = []
        for u in usages {
            // Interpreters stay one line per script: Python.app of the framework would merge them all.
            if u.arguments.isEmpty, let path = u.path, let bundle = appBundle(of: path) {
                apps[(bundle as NSString).lastPathComponent, default: []].append((bundle, u))
            } else { loose.append(u) }
        }
        let merged = apps.map { appName, members -> ProcessUsage in
            // The main executable sits in the outer bundle's Contents/MacOS, with no nested bundle on the way.
            let isMain = { (path: String?) in
                guard let path else { return false }
                return (path as NSString).deletingLastPathComponent.hasSuffix("/Contents/MacOS") && path.components(separatedBy: ".app").count == 2
            }
            let main = members.first { isMain($0.usage.path) } ?? members[0]
            let installed = members.first { !$0.bundle.hasPrefix("/private/") && !$0.bundle.hasPrefix("/var/") } ?? members[0]
            return ProcessUsage(pid: main.usage.pid, name: (appName as NSString).deletingPathExtension, path: installed.bundle,
                                cpuPercent: members.reduce(0) { $0 + $1.usage.cpuPercent },
                                memory: members.reduce(0) { $0 + $1.usage.memory })
        }
        return merged + loose
    }
}


// MARK: - Readers

extension SystemSampler {
    static func sysctl<T>(_ name: String, as _: T.Type = T.self) -> T? {
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { p.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, p, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return p.pointee
    }

    static func cpuTicks(_ host: host_t) -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(task_self_trap(), vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var t: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            t.user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            t.system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            t.idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            t.nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        return t
    }

    static func memory(_ host: host_t) -> MemoryUsage {
        var m = MemoryUsage(total: Int64(ProcessInfo.processInfo.physicalMemory))
        var pageSize: vm_size_t = 0
        if host_page_size(host, &pageSize) != KERN_SUCCESS { pageSize = vm_size_t(getpagesize()) }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = Int64(pageSize)
            m.app = Int64(stats.internal_page_count &- stats.purgeable_count) * page
            m.wired = Int64(stats.wire_count) * page
            m.compressed = Int64(stats.compressor_page_count) * page
            m.cache = Int64(stats.external_page_count + stats.purgeable_count) * page
        }
        // Same values as DISPATCH_MEMORYPRESSURE_NORMAL / WARN / CRITICAL.
        switch sysctl("kern.memorystatus_vm_pressure_level", as: Int32.self) {
        case 4: m.pressure = .critical
        case 2: m.pressure = .warning
        default: m.pressure = .normal
        }
        if let swap = sysctl("vm.swapusage", as: xsw_usage.self) {
            m.swapTotal = Int64(swap.xsu_total)
            m.swapUsed = Int64(swap.xsu_used)
        }
        return m
    }

    static func disk() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys), let total = v.volumeTotalCapacity else { return nil }
        let free = Int64(v.volumeAvailableCapacity ?? 0)
        let available = v.volumeAvailableCapacityForImportantUsage ?? free
        return DiskUsage(total: Int64(total), available: available, purgeable: max(0, available - free))
    }

    static func battery() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let ps = list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let ps else { return nil }

        let current = ps[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = ps[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = ps[kIOPSIsChargingKey] as? Bool ?? false
        let minutes = ps[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
        let health = ps["BatteryHealth"] as? String
        let condition = ps["BatteryHealthCondition"] as? String
        var b = BatteryInfo(
            percent: max > 0 ? Swift.min(100, current * 100 / max) : current,
            isCharging: charging,
            isPluggedIn: ps[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            serviceRecommended: ["Poor", "Check Battery"].contains(health ?? "") || !(condition ?? "").isEmpty,
            minutesRemaining: minutes.flatMap { $0 >= 0 ? $0 : nil }
        )

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return b }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let reg = props?.takeRetainedValue() as? [String: Any] else { return b }
        b.cycleCount = reg["CycleCount"] as? Int
        // On Apple Silicon `MaxCapacity` is a percentage. Recent macOS versions move the mAh figures into `BatteryData`;
        // `NominalChargeCapacity / DesignCapacity` matches "Maximum Capacity" in System Settings.
        let data = reg["BatteryData"] as? [String: Any] ?? [:]
        let design = reg["DesignCapacity"] as? Int ?? data["DesignCapacity"] as? Int ?? 0
        let raw = reg["AppleRawMaxCapacity"] as? Int ?? data["NominalChargeCapacity"] as? Int ?? data["FullChargeCapacity"] as? Int ?? 0
        if design > 0, raw > 100 { b.healthPercent = Swift.min(100, Double(raw) / Double(design) * 100) }
        if let t = reg["Temperature"] as? Int ?? data["Temperature"] as? Int, t > 0 { b.temperatureCelsius = Double(t) / 100 }
        return b
    }

    static func interfaceCounters() -> [String: (inBytes: UInt32, outBytes: UInt32)] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [:] }
        defer { freeifaddrs(ifap) }
        var result: [String: (inBytes: UInt32, outBytes: UInt32)] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            // Physical interfaces only: tunnels (utun, VPN) carry traffic already counted on en*.
            guard name.hasPrefix("en") else { continue }
            let d = data.load(as: if_data.self)
            result[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        return result
    }

    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "VibeCleaner" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = dict["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    static func uptime() -> TimeInterval {
        guard let boot = sysctl("kern.boottime", as: timeval.self), boot.tv_sec > 0 else { return ProcessInfo.processInfo.systemUptime }
        let bootDate = Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
        return max(0, Date().timeIntervalSince(bootDate))
    }

    /// nil when the folder cannot be listed (Full Disk Access missing).
    static func trashSize(home: URL) -> Int64? {
        let trash = home.appendingPathComponent(".Trash")
        guard (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) != nil else { return nil }
        return FileSizer.size(of: trash)
    }

    struct RawProcess {
        let pid: Int32
        let name: String
        let path: String?
        let cpuNanos: UInt64
        let memory: Int64
        var start: UInt64? = nil
    }

    static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(max(1, tb.numer)), UInt64(max(1, tb.denom)))
    }()

    static func processes() -> [RawProcess] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }

        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 4 * Int(MAXPATHLEN))
        defer { pathBuffer.deallocate() }
        var result: [RawProcess] = []
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }
            // Task times are in Mach absolute time units (not nanoseconds on Apple Silicon).
            let ticks = task.pti_total_user + task.pti_total_system
            let nanos = ticks.multipliedReportingOverflow(by: timebase.numer).partialValue / timebase.denom

            var memory = Int64(task.pti_resident_size)
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            if ok == 0 { memory = Int64(usage.ri_phys_footprint) }

            var path: String?
            if proc_pidpath(pid, pathBuffer, UInt32(4 * MAXPATHLEN)) > 0 { path = String(cString: pathBuffer) }
            var name = path.map { ($0 as NSString).lastPathComponent } ?? ""
            if name.isEmpty, proc_name(pid, pathBuffer, UInt32(4 * MAXPATHLEN)) > 0 { name = String(cString: pathBuffer) }
            result.append(RawProcess(pid: pid, name: name.isEmpty ? "PID \(pid)" : name, path: path, cpuNanos: nanos, memory: memory,
                                     start: ProcessStopper.startTime(pid)))
        }
        return result
    }
}
