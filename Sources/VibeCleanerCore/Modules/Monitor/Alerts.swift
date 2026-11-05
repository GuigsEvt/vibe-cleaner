import Foundation

/// Background alerts: low disk space, full Trash,
/// low RAM, the Vibe Check reminder, trashed apps, low accessory battery, drive connected and external disk almost full.
/// Pure logic; the app samples, persists and posts.
/// Non-responsive apps are left out: the WindowServer flag is private (`CGSEventIsAppUnresponsive`) and the public
/// workaround (Accessibility timeouts) needs an Accessibility authorization the app does not ask for.
public enum AlertKind: String, Sendable, CaseIterable, Codable {
    case lowDisk, trashFull, lowRAM, vibeCheckReminder, trashedApp, accessoryBattery, driveConnected, externalLow
}

public struct Alert: Sendable, Hashable {
    public let kind: AlertKind
    public let title: String
    public let body: String
    /// Module the notification opens.
    public let module: String
    /// What the alert is about (accessory ids, trashed app paths), recorded so it is not repeated.
    public var subjects: [String] = []
}

/// Readings that don't come from `SystemSnapshot`.
public struct AlertInputs: Sendable {
    public var accessories: [PeripheralBattery]
    public var trashedApps: [TrashWatch.App]
    /// False when the Trash was not looked at (alert off, or no Full Disk Access): what was seen is then forgotten,
    /// so the next real look only records the apps already there instead of reporting them all.
    public var trashWatched: Bool
    public var externalVolumes: [ExternalVolume]

    public init(accessories: [PeripheralBattery] = [], trashedApps: [TrashWatch.App] = [], trashWatched: Bool = true,
                externalVolumes: [ExternalVolume] = []) {
        self.accessories = accessories
        self.trashedApps = trashedApps
        self.trashWatched = trashWatched
        self.externalVolumes = externalVolumes
    }
}

/// "Ignorer pour…" options.
public enum SnoozeOption: String, Sendable, CaseIterable {
    case untilTomorrow, day, threeDays, week, forever

    public var title: String {
        switch self {
        case .untilTomorrow: "Jusqu'à demain"
        case .day: "Pendant un jour"
        case .threeDays: "Pendant 3 jours"
        case .week: "Pendant une semaine"
        case .forever: "Toujours"
        }
    }

    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .untilTomorrow: calendar.startOfDay(for: now.addingTimeInterval(86_400))
        case .day: now.addingTimeInterval(86_400)
        case .threeDays: now.addingTimeInterval(3 * 86_400)
        case .week: now.addingTimeInterval(7 * 86_400)
        case .forever: .distantFuture
        }
    }
}

public struct AlertSettings: Sendable {
    public var lowDisk = true
    public var diskThreshold: Int64 = 10_000_000_000
    public var trash = true
    public var trashThreshold: Int64 = 2_000_000_000
    public var lowRAM = true
    public var reminder = true
    public var reminderInterval: TimeInterval = 7 * 86_400
    public var trashedApps = true
    public var accessoryBattery = true
    public var driveConnected = true
    public var externalLow = true

    /// External disk alert under 10 % free.
    public static let externalLowFraction = 0.10

    /// alert under 20 %, postponed until 50 % or 24 h.
    public static let accessoryLowPercent = 20
    public static let accessoryChargedPercent = 50
    public static let accessoryPostpone: TimeInterval = 86_400

    public init() {}

    /// Choices offered in the settings: decimal gigabytes, as Finder counts.
    public static let diskThresholds: [Int64] = [2, 5, 10, 20, 30, 50, 100].map { $0 * 1_000_000_000 }
    public static let trashThresholds: [Int64] = [0.5, 1, 2, 3, 5, 10, 15, 20, 30, 50, 100].map { Int64($0 * 1_000_000_000) }
    public static let reminderIntervals: [(String, TimeInterval)] = [
        ("Tous les 3 jours", 3 * 86_400), ("Chaque semaine", 7 * 86_400), ("Toutes les 2 semaines", 14 * 86_400), ("Chaque mois", 30 * 86_400),
    ]

    /// Default disk threshold: the option closest to 10 % of the boot volume, 100 GB when unknown.
    public static func defaultDiskThreshold(capacity: Int64?) -> Int64 {
        guard let capacity, capacity > 0 else { return 100_000_000_000 }
        return diskThresholds.min { abs($0 - capacity / 10) < abs($1 - capacity / 10) }!
    }
}

/// What the app remembers between evaluations.
public struct AlertState: Sendable, Codable, Equatable {
    public var snoozedUntil: [AlertKind: Date] = [:]
    public var lastSent: [AlertKind: Date] = [:]
    public var lastVibeCheck: Date?
    public var firstLaunch: Date
    /// Accessories already reported low, with the date (optional: older saved states lack them).
    public var accessoriesNotified: [String: Date]?
    /// Trashed app paths already reported; nil until the first look, which only records what is there.
    public var trashedAppsSeen: [String]?

    public init(firstLaunch: Date) { self.firstLaunch = firstLaunch }

    public mutating func snooze(_ kind: AlertKind, _ option: SnoozeOption, now: Date = Date()) {
        snoozedUntil[kind] = option.until(from: now)
    }

    public func isSnoozed(_ kind: AlertKind, now: Date = Date()) -> Bool {
        (snoozedUntil[kind] ?? .distantPast) > now
    }

    /// Records a posted alert.
    public mutating func markSent(_ alert: Alert, now: Date = Date()) {
        lastSent[alert.kind] = now
        switch alert.kind {
        case .accessoryBattery:
            var n = accessoriesNotified ?? [:]
            for id in alert.subjects { n[id] = now }
            accessoriesNotified = n
        case .trashedApp:
            trashedAppsSeen = Array(Set(trashedAppsSeen ?? []).union(alert.subjects)).sorted()
        default: break
        }
    }

    /// Before `due`: forgets charged accessories and apps no longer in the Trash. The first look at the Trash
    /// marks its current apps as seen, so only apps trashed afterwards raise the alert.
    public mutating func prune(_ inputs: AlertInputs) {
        if var n = accessoriesNotified {
            for a in inputs.accessories where a.percent >= AlertSettings.accessoryChargedPercent { n[a.id] = nil }
            accessoriesNotified = n
        }
        guard inputs.trashWatched else { trashedAppsSeen = nil; return }
        let present = Set(inputs.trashedApps.map(\.id))
        trashedAppsSeen = trashedAppsSeen.map { $0.filter(present.contains) } ?? present.sorted()
    }
}

public enum AlertPolicy {
    /// At most one alert of a kind per hour.
    public static let cooldown: TimeInterval = 3_600

    /// Alerts to post now; the caller records them in `lastSent`.
    public static func due(snapshot s: SystemSnapshot, settings: AlertSettings, state: AlertState, inputs: AlertInputs = AlertInputs(),
                           now: Date = Date()) -> [Alert] {
        var out: [Alert] = []
        if settings.lowDisk, let d = s.disk, d.total > 0, d.available < settings.diskThreshold {
            out.append(Alert(kind: .lowDisk, title: "Espace disque presque épuisé",
                             body: "Il reste \(FileSizer.format(d.available)) sur le disque de démarrage.", module: "junk"))
        }
        if settings.trash, let t = s.trashSize, t > settings.trashThreshold {
            out.append(Alert(kind: .trashFull, title: "Il est temps de vider la corbeille",
                             body: "Elle occupe \(FileSizer.format(t)), au-delà de la limite de \(FileSizer.format(settings.trashThreshold)) que vous avez fixée.",
                             module: "junk"))
        }
        let m = s.memory
        if settings.lowRAM, m.pressure == .critical || (m.pressure == .warning && m.swapFraction > HealthAssessment.Threshold.swapFraction) {
            out.append(Alert(kind: .lowRAM, title: "Mémoire presque pleine",
                             body: "La mémoire vive et le swap sont presque pleins. Quittez les apps que vous n'utilisez pas.", module: "performance"))
        }
        if let date = reminderDate(settings: settings, state: state), now >= date {
            out.append(reminder(state))
        }
        if settings.trashedApps {
            let seen = Set(state.trashedAppsSeen ?? inputs.trashedApps.map(\.id))
            let new = inputs.trashedApps.filter { !seen.contains($0.id) }
            if !new.isEmpty {
                let names = new.map(\.name).joined(separator: ", ")
                out.append(Alert(kind: .trashedApp, title: "Désinstallez les applications correctement",
                                 body: "\(names) \(new.count > 1 ? "sont" : "est") dans la corbeille, mais \(new.count > 1 ? "leurs" : "ses") fichiers liés restent sur le Mac. Supprimez-les avec le module Applications.",
                                 module: "applications", subjects: new.map(\.id)))
            }
        }
        if settings.externalLow {
            let full = inputs.externalVolumes.filter {
                $0.total > 0 && !$0.isReadOnly && Double($0.available) / Double($0.total) < AlertSettings.externalLowFraction
            }
            if !full.isEmpty {
                out.append(Alert(kind: .externalLow, title: full.count > 1 ? "Disques externes presque pleins" : "Disque externe presque plein",
                                 body: full.map { "« \($0.name) » : \(FileSizer.format($0.available)) libres sur \(FileSizer.format($0.total))" }
                                     .joined(separator: ", ") + ". Explorez-le dans le Radar pour faire de la place.",
                                 module: "radar", subjects: full.map(\.id)))
            }
        }
        if settings.accessoryBattery {
            let notified = state.accessoriesNotified ?? [:]
            let low = inputs.accessories.filter { a in
                a.percent < AlertSettings.accessoryLowPercent
                    && notified[a.id].map { now.timeIntervalSince($0) >= AlertSettings.accessoryPostpone } ?? true
            }
            if !low.isEmpty {
                out.append(Alert(kind: .accessoryBattery, title: "Il est temps de recharger",
                                 body: low.map { "\($0.name) : \($0.percent) %" }.joined(separator: ", "),
                                 module: "vibecheck", subjects: low.map(\.id)))
            }
        }
        return out.filter { a in
            if let until = state.snoozedUntil[a.kind], until > now { return false }
            if let last = state.lastSent[a.kind], now.timeIntervalSince(last) < cooldown { return false }
            return true
        }
    }

    public static func reminder(_ state: AlertState) -> Alert {
        Alert(kind: .vibeCheckReminder, title: "Un petit entretien ?",
              body: state.lastVibeCheck == nil ? "Vous n'avez pas encore lancé Vibe Check." : "Votre dernier Vibe Check date un peu. Lancez-en un pour garder votre Mac en forme.",
              module: "vibecheck")
    }

    /// When the Vibe Check reminder is due: interval after the last Vibe Check (or first launch), or after the last
    /// reminder. Also used to schedule the local notification that reaches the user while the app is closed.
    public static func reminderDate(settings: AlertSettings, state: AlertState) -> Date? {
        guard settings.reminder else { return nil }
        let since = max(state.lastVibeCheck ?? state.firstLaunch, state.lastSent[.vibeCheckReminder] ?? .distantPast)
        return since.addingTimeInterval(settings.reminderInterval)
    }
}
