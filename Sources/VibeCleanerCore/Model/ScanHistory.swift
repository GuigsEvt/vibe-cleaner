import Foundation

/// Last scan date per module id ("vibecheck", "junk"…), for the Guide's "no recent scan" factors.
public enum ScanHistory {
    static func key(_ moduleID: String) -> String { "scanHistory.\(moduleID)" }

    public static func record(_ moduleID: String, at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: key(moduleID))
    }

    public static func last(_ moduleID: String, in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: key(moduleID)) as? Date
    }
}
