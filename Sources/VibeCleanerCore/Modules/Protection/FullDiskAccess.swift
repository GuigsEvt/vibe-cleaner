import Foundation

/// Full Disk Access can't be queried directly; reading a file that only FDA opens is the standard probe.
/// These files never show a permission prompt: without FDA the read just fails.
public enum FullDiskAccess {
    public static var isGranted: Bool { isGranted(home: NSHomeDirectory()) }

    static func isGranted(home h: String) -> Bool {
        // The user TCC.db is missing on some systems, so Safari's folder, which always exists, is listed too.
        let probes = ["\(h)/Library/Application Support/com.apple.TCC/TCC.db", "\(h)/Library/Safari/Bookmarks.plist",
                      "\(h)/Library/Safari/CloudTabs.db", "/Library/Preferences/com.apple.TimeMachine.plist"]
        if probes.contains(where: { (try? FileHandle(forReadingFrom: URL(fileURLWithPath: $0)))?.readData(ofLength: 16).isEmpty == false }) {
            return true
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: "\(h)/Library/Safari")) != nil
    }

    /// Folders of the home whose first access shows a macOS permission prompt, or is refused, without FDA.
    public static func promptingFolders(home: URL) -> [String] {
        ["Downloads", "Desktop", "Documents", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers",
         "Library/Group Containers", "Library/Mobile Documents", "Library/CloudStorage", "Library/Cookies", "Library/Keychains",
         "Library/Application Support/com.apple.TCC", "Library/Application Support/AddressBook", "Library/Calendars",
         "Library/Reminders", "Library/HomeKit", "Library/Suggestions", "Library/Metadata/CoreSpotlight",
         "Pictures/Photos Library.photoslibrary"].map { home.appendingPathComponent($0).path }
    }

    /// True when `path` is one of `folders` or lies inside one.
    static func isUnder(_ path: String, _ folders: [String]) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
