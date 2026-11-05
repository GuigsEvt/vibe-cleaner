import Foundation
import VibeCleanerCore

/// Preferences of the menu bar, the Guide and the extra alerts.
extension Prefs {
    static let alertTrashedApps = "alertTrashedApps"
    static let alertAccessoryBattery = "alertAccessoryBattery"
    static let alertDriveConnected = "alertDriveConnected"
    static let alertExternalLow = "alertExternalLow"
    /// JSON `[factor id: skipped until]`.
    static let guideSkipped = "guideSkipped"
    /// Shows the factor simulation panel in the Guide (also shown when Option is held on opening).
    static let guideDebug = "guideDebug"
    /// `ScanHistory` id of Protection scans run in deep mode.
    static let deepScanHistoryID = "protection.deep"

    static let historyModules = ["vibecheck", "junk", "protection", "performance", "applications", "clutter", "cloud"]

    static func monitorAlertSettings(capacity: Int64?) -> AlertSettings {
        var s = alertSettings(capacity: capacity)
        s.trashedApps = MonitorKeys.flag(alertTrashedApps)
        s.accessoryBattery = MonitorKeys.flag(alertAccessoryBattery)
        s.driveConnected = MonitorKeys.flag(alertDriveConnected)
        s.externalLow = MonitorKeys.flag(alertExternalLow)
        return s
    }

    static func guideFacts(drive: DriveHealth) -> HealthAssessment.Facts {
        var f = healthFacts
        f.drive = drive
        f.menuEnabled = MonitorKeys.flag(MonitorKeys.menuBarEnabled)
        f.malwareMonitorEnabled = MonitorKeys.flag(MonitorKeys.protectionMonitorEnabled)
        f.lastScans = historyModules.reduce(into: [:]) { $0[$1] = ScanHistory.last($1) }
        f.lastDeepScan = ScanHistory.last(deepScanHistoryID)
        f.vibeCheckInterval = alertSettings(capacity: nil).reminderInterval
        return f
    }

    static var guideSkips: [String: Date] {
        get {
            guard let data = UserDefaults.standard.data(forKey: guideSkipped),
                  let s = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
            return s
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: guideSkipped) }
    }
}

/// Keys shared with the settings screens written elsewhere; kept out of `Prefs` so both can coexist.
enum MonitorKeys {
    static let menuBarEnabled = "menuBarEnabled"
    static let protectionMonitorEnabled = "protectionMonitorEnabled"
    static let menuShowExternalDisks = "menuShowExternalDisks"
    static let showMenuRecommendations = "showMenuRecommendations"

    /// Bool preference that defaults to true.
    static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}
