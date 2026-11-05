import Foundation
import IOKit

/// SMART status of the startup drive as `diskutil` reports it (no private IOKit user client).
public enum DriveHealth: String, Sendable, Hashable {
    case verified, failing, notSupported, unknown

    public init(diskutilValue v: String) {
        switch v.trimmingCharacters(in: .whitespaces).lowercased() {
        case "verified": self = .verified
        case "failing", "about to fail": self = .failing
        case "not supported": self = .notSupported
        default: self = .unknown
        }
    }

    /// `diskutil info -plist` output.
    public static func parse(plist data: Data) -> DriveHealth {
        guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = d["SMARTStatus"] as? String else { return .unknown }
        return DriveHealth(diskutilValue: v)
    }

    /// `diskutil info` text output ("   SMART Status:   Verified").
    public static func parse(text: String) -> DriveHealth {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "SMART Status" {
                return DriveHealth(diskutilValue: String(parts[1]))
            }
        }
        return .unknown
    }

    /// Read-only; about 50 ms.
    public static func read(volume: String = "/") -> DriveHealth {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", volume])
        return r.ok ? parse(plist: Data(r.stdout.utf8)) : .unknown
    }

    public var title: String {
        switch self {
        case .verified: "Bon état"
        case .failing: "Défaillant"
        case .notSupported: "Non pris en charge"
        case .unknown: "Inconnu"
        }
    }

    public var detail: String {
        switch self {
        case .verified: "Ce disque est en bon état."
        case .failing: "Le disque signale une défaillance. Sauvegardez vos données immédiatement."
        case .notSupported, .unknown: "L'état SMART de ce disque n'est pas disponible."
        }
    }
}

/// Model of this Mac for the Guide's device view.
public struct MacModel: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case laptop, imac, mini, studio, pro, generic }

    public var name: String
    public var chip: String?

    public init(name: String, chip: String? = nil) {
        self.name = name
        self.chip = chip
    }

    public var kind: Kind {
        let n = name.lowercased()
        if n.contains("macbook") { return .laptop }
        if n.contains("imac") { return .imac }
        if n.contains("mini") { return .mini }
        if n.contains("studio") { return .studio }
        if n.contains("mac pro") { return .pro }
        return .generic
    }

    /// SF Symbol for `kind`.
    public var symbol: String {
        switch kind {
        case .laptop: "laptopcomputer"
        case .imac: "desktopcomputer"
        case .mini: "macmini"
        case .studio: "macstudio"
        case .pro: "macpro.gen3"
        case .generic: "desktopcomputer"
        }
    }

    /// `system_profiler SPHardwareDataType -json` output.
    public static func parse(systemProfilerJSON json: String) -> MacModel? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let hw = (obj["SPHardwareDataType"] as? [[String: Any]])?.first,
              let name = hw["machine_name"] as? String else { return nil }
        return MacModel(name: name, chip: hw["chip_type"] as? String ?? hw["cpu_type"] as? String)
    }

    public static func read() -> MacModel {
        let r = Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"])
        return parse(systemProfilerJSON: r.stdout) ?? MacModel(name: "Mac")
    }
}

/// A Bluetooth or USB accessory reporting its battery in the IORegistry (Magic Keyboard, Mouse, Trackpad…).
public struct PeripheralBattery: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var percent: Int

    public init(id: String, name: String, percent: Int) {
        self.id = id
        self.name = name
        self.percent = percent
    }

    public var symbol: String {
        let n = name.lowercased()
        if n.contains("keyboard") || n.contains("clavier") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("mouse") || n.contains("souris") { return "computermouse" }
        if n.contains("airpods") || n.contains("beats") { return "airpods" }
        return "dot.radiowaves.left.and.right"
    }

    /// IORegistry class read without entitlement or Bluetooth permission.
    public static let registryClass = "AppleDeviceManagementHIDEventService"

    /// One entry per device from the services' properties; a keyboard exposes several services.
    public static func parse(_ services: [[String: Any]]) -> [PeripheralBattery] {
        var seen = Set<String>()
        var out: [PeripheralBattery] = []
        for p in services {
            guard let percent = (p["BatteryPercent"] as? NSNumber)?.intValue, (0...100).contains(percent) else { continue }
            let name = p["Product"] as? String ?? "Appareil"
            let id = p["DeviceAddress"] as? String ?? p["SerialNumber"] as? String ?? name
            guard seen.insert(id).inserted else { continue }
            out.append(PeripheralBattery(id: id, name: name, percent: percent))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func read() -> [PeripheralBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(registryClass), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] { services.append(dict) }
            IOObjectRelease(service)
        }
        return parse(services)
    }
}

/// A mounted external volume, as the menu's External Drives widget lists it.
public struct ExternalVolume: Identifiable, Sendable, Hashable {
    public var url: URL
    public var name: String
    public var total: Int64
    public var available: Int64
    public var isReadOnly: Bool
    public var id: String { url.path }

    public init(url: URL, name: String, total: Int64, available: Int64, isReadOnly: Bool) {
        self.url = url
        self.name = name
        self.total = total
        self.available = available
        self.isReadOnly = isReadOnly
    }

    /// Volumes under /Volumes, browsable and not internal.
    public static func isListed(path: String, isInternal: Bool?, isBrowsable: Bool?) -> Bool {
        path.hasPrefix("/Volumes/") && isInternal != true && isBrowsable != false
    }

    static let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
                                         .volumeTotalCapacityKey, .volumeAvailableCapacityKey]

    public static func load(_ url: URL) -> ExternalVolume? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)),
              isListed(path: url.path, isInternal: v.volumeIsInternal, isBrowsable: v.volumeIsBrowsable) else { return nil }
        return ExternalVolume(url: url, name: v.volumeName ?? url.lastPathComponent, total: Int64(v.volumeTotalCapacity ?? 0),
                              available: Int64(v.volumeAvailableCapacity ?? 0), isReadOnly: v.volumeIsReadOnly ?? false)
    }

    public static func mounted() -> [ExternalVolume] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .compactMap(load)
    }
}

/// Which running processes get a "Quitter" button: regular apps only, never system processes.
public enum QuitPolicy {
    static let protectedIDs: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
                                            "com.apple.controlcenter", "com.apple.WindowManager", "com.apple.notificationcenterui"]

    public static func canQuit(bundleID: String?, bundlePath: String?, isRegularApp: Bool, ownBundleID: String?) -> Bool {
        guard isRegularApp, let path = bundlePath, path.hasSuffix(".app") else { return false }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/") { return false }
        if let id = bundleID, protectedIDs.contains(id) || id == ownBundleID { return false }
        return true
    }
}
