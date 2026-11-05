import Foundation
import VibeCleanerCore

extension Prefs {
    /// Real-time monitor (LaunchAgents, Downloads) while the app runs. Read by the `malware_monitor_off` factor.
    static let protectionMonitorEnabled = "protectionMonitorEnabled"
    /// Daily quick malware scan while the app runs.
    static let protectionBackgroundScan = "protectionBackgroundScan"
    static let protectionLastBackgroundScan = "protectionLastBackgroundScan"
    static let protectionScanDMG = "protectionScanDMG"
    static let protectionScanArchives = "protectionScanArchives"
    static let protectionScanMail = "protectionScanMail"
    /// Off by default: external volumes are read only with Full Disk Access anyway.
    static let protectionScanUSB = "protectionScanUSB"

    static func protectionFlag(_ key: String, default value: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    /// Applies the Protection settings (and, for the Protection screen, a pending custom scan) to the module.
    static func configureProtection(_ m: inout ProtectionModule, customScan: Bool = true) {
        let d = UserDefaults.standard
        m.depth = ProtectionModule.ScanDepth(rawValue: d.string(forKey: protectionDepth) ?? "") ?? .balanced
        m.excludedTeamIDs = Set(lines("excludedTeamIDs").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        m.scanDiskImages = protectionFlag(protectionScanDMG, default: false)
        m.scanArchives = protectionFlag(protectionScanArchives, default: false)
        m.scanMailAttachments = protectionFlag(protectionScanMail)
        m.fullDiskAccess = Permissions.hasFullDiskAccess
        m.scanExternalDrives = protectionFlag(protectionScanUSB, default: false)
        if customScan { m.customRoots = ProtectionCustomScan.consume() }
    }
}

/// Folders picked for the next Protection scan, consumed once by `Prefs.configureProtection`.
enum ProtectionCustomScan {
    nonisolated(unsafe) static var pending: [URL] = []

    static func consume() -> [URL] {
        defer { pending = [] }
        return pending
    }
}
