import Foundation

public enum HealthStatus: Sendable, Hashable, CaseIterable {
    case excellent, good, fair, poor, critical

    /// ≥ 90 Excellent, 75–89 Good, 50–74 Fair, 25–49 Requires Attention, < 25 Critical.
    public init(score: Int) {
        switch score {
        case 90...: self = .excellent
        case 75...: self = .good
        case 50...: self = .fair
        case 25...: self = .poor
        default: self = .critical
        }
    }

    public var title: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Bon"
        case .fair: "Correct"
        case .poor: "Attention requise"
        case .critical: "Critique"
        }
    }

    public var summary: String {
        switch self {
        case .excellent: "Votre Mac se porte très bien. Un entretien régulier le gardera ainsi."
        case .good: "Votre Mac est en bonne forme. Un peu d'entretien le rendrait encore plus performant."
        case .fair: "Votre Mac va bien, mais quelques opérations d'entretien sont recommandées."
        case .poor: "Votre Mac ne va pas très bien. Occupez-vous des problèmes ci-dessous."
        case .critical: "Nous vous recommandons vivement d'agir dès maintenant."
        }
    }
}

public enum IssueSeverity: Int, Sendable, Hashable, Comparable {
    case info, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct HealthIssue: Identifiable, Sendable, Hashable {
    /// Factor identifier (`out_of_disk_space`, `uptime`...).
    public let id: String
    public var title: String
    public var detail: String
    public var severity: IssueSeverity
    /// Points removed from the 100-point score.
    public var penalty: Int
    /// Higher shows first; the top one is the menu's "Recommandation du jour".
    public var priority: Int
    /// Module that addresses the issue ("junk", "performance"...); nil when nothing in the app can fix it.
    public var module: String?

    public init(id: String, title: String, detail: String, severity: IssueSeverity, penalty: Int, priority: Int, module: String?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.severity = severity
        self.penalty = penalty
        self.priority = priority
        self.module = module
    }
}

/// Deterministic Mac health score: `maxScore − Σ penalties` of the active rules, clamped to 0...100.
public struct HealthAssessment: Sendable, Hashable {
    public static let maxScore = 100

    /// Default thresholds.
    public enum Threshold {
        public static let lowDiskBytes: Int64 = 10_000_000_000
        public static let lowDiskFraction = 0.05
        public static let trashBytes: Int64 = 5_000_000_000
        public static let uptime: TimeInterval = 7 * 86_400
        /// Low RAM also fires on warning pressure when swap use exceeds this share of allocated swap.
        public static let swapFraction = 0.75
    }

    /// Penalties of each factor.
    public enum Penalty {
        public static let malware = 100
        /// Heuristic findings (unsigned launch item, extension, process): once, whatever their number.
        public static let toReview = 10
        public static let criticalBattery = 80
        public static let noFullDiskAccess = 10
        public static let unusedApps = 10
        public static let lowDisk = 20
        public static let lowMemory = 10
        public static let trash = 5
        public static let uptime = 5
        public static let hotBattery = 0
        public static let criticalDrive = 100
        public static let menuOff = 10
        public static let monitorOff = 20
        public static let noVibeCheck = 10
        public static let noDeepScan = 5
        /// The module invitations only rank, they don't lower the score.
        public static let noModuleScan = 0
    }

    /// "Recently" windows for the scan invitations. Chosen windows (Vibe Check follows the reminder setting).
    public enum Recency {
        public static let vibeCheck: TimeInterval = 7 * 86_400
        public static let module: TimeInterval = 14 * 86_400
        public static let deepScan: TimeInterval = 30 * 86_400
    }

    /// Modules Vibe Check covers: while Vibe Check itself is overdue, its invitation stands for them (recommendation group).
    public static let vibeCheckModules = ["junk", "protection", "performance", "applications", "clutter"]
    /// Invitation factor id per module id.
    public static let recencyFactors: [(module: String, id: String, title: String)] = [
        ("junk", "no_cleanup_recently", "Recherchez les fichiers inutiles"),
        ("protection", "no_protection_recently", "Analysez votre Mac à la recherche de menaces"),
        ("performance", "no_performance_recently", "Lancez l'entretien régulier"),
        ("applications", "no_applications_recently", "Faites le point sur vos applications"),
        ("clutter", "no_myclutter_recently", "Rangez vos fichiers encombrants"),
        ("cloud", "no_cloud_recently", "Faites le tri dans votre stockage cloud"),
    ]

    public let score: Int
    public let status: HealthStatus
    /// Sorted by priority, highest first.
    public let issues: [HealthIssue]

    /// Facts that don't come from sampling: permissions and the latest scans.
    public struct Facts: Sendable {
        public var hasFullDiskAccess = true
        /// Sure threats left by the latest Protection scan (rule or hash matched).
        public var threats = 0
        /// Heuristic findings still to check, minus those whose risk the user accepted.
        public var toReview = 0
        /// Unused apps found by the latest Applications scan.
        public var unusedApps = 0
        /// SMART status of the startup drive.
        public var drive: DriveHealth = .unknown
        public var menuEnabled = true
        public var malwareMonitorEnabled = true
        /// Last scan per module id (`ScanHistory`); nil leaves the "no recent scan" factors out.
        public var lastScans: [String: Date]?
        /// Last Protection scan in deep mode.
        public var lastDeepScan: Date?
        public var vibeCheckInterval = Recency.vibeCheck
        public var now = Date()

        public init(hasFullDiskAccess: Bool = true, threats: Int = 0, unusedApps: Int = 0) {
            self.hasFullDiskAccess = hasFullDiskAccess
            self.threats = threats
            self.unusedApps = unusedApps
        }
    }

    /// `lowDiskBytes` and `trashBytes` come from the notification settings when the user changed them.
    public init(snapshot s: SystemSnapshot, facts: Facts = Facts(), lowDiskBytes: Int64 = Threshold.lowDiskBytes,
                trashBytes: Int64 = Threshold.trashBytes) {
        var issues: [HealthIssue] = []

        if facts.threats > 0 {
            issues.append(HealthIssue(id: "malware_detected", title: "Réagissez aux menaces détectées",
                                      detail: "\(facts.threats) menace(s) détectée(s) lors de la dernière analyse Protection.",
                                      severity: .critical, penalty: Penalty.malware, priority: 1500, module: "protection"))
        }

        if facts.toReview > 0 {
            issues.append(HealthIssue(id: "items_to_review", title: "Vérifiez les éléments signalés",
                                      detail: "\(facts.toReview) élément(s) à vérifier dans Protection : examinez-les, ou acceptez le risque.",
                                      severity: .warning, penalty: Penalty.toReview, priority: 1100, module: "protection"))
        }

        if facts.drive == .failing {
            issues.append(HealthIssue(id: "critical_drive_health", title: "Santé du disque critique",
                                      detail: "Le disque de démarrage signale une défaillance SMART. Sauvegardez vos données immédiatement.",
                                      severity: .critical, penalty: Penalty.criticalDrive, priority: 1400, module: nil))
        }

        if !facts.menuEnabled {
            issues.append(HealthIssue(id: "disabled_menu", title: "Le menu Vibe Cleaner est désactivé",
                                      detail: "Sans lui, vous ne voyez plus l'état de votre Mac dans la barre des menus.",
                                      severity: .info, penalty: Penalty.menuOff, priority: 850, module: nil))
        }

        if !facts.malwareMonitorEnabled {
            issues.append(HealthIssue(id: "malware_monitor_off", title: "La surveillance des menaces est désactivée",
                                      detail: "Réactivez-la pour être prévenu des menaces sans lancer d'analyse.",
                                      severity: .warning, penalty: Penalty.monitorOff, priority: 750, module: nil))
        }

        if let scans = facts.lastScans {
            issues += Self.recencyIssues(scans: scans, deep: facts.lastDeepScan, vibeCheckInterval: facts.vibeCheckInterval, now: facts.now)
        }

        if !facts.hasFullDiskAccess {
            // Just under sure threats: without it the Trash, most caches and Protection are out of reach.
            issues.append(HealthIssue(id: "no_fda", title: "Accordez l'accès complet au disque",
                                      detail: "Sans lui, Vibe Cleaner ne peut ni vider la corbeille, ni analyser la plupart des caches, la protection et la vie privée.",
                                      severity: .critical, penalty: Penalty.noFullDiskAccess, priority: 1450, module: nil))
        }

        if facts.unusedApps > 0 {
            issues.append(HealthIssue(id: "unused_apps", title: "Désinstallez les apps inutilisées",
                                      detail: "\(facts.unusedApps) app(s) non ouverte(s) depuis plus de 6 mois.",
                                      severity: .info, penalty: Penalty.unusedApps, priority: 600, module: "applications"))
        }

        if let b = s.battery, b.healthLevel == .critical {
            let detail = b.serviceRecommended
                ? "macOS recommande de faire réviser la batterie."
                : "La batterie ne conserve plus que \(Int(b.healthPercent ?? 0)) % de sa capacité d'origine."
            issues.append(HealthIssue(id: "critical_battery_health", title: "Santé de la batterie critique", detail: detail,
                                      severity: .critical, penalty: Penalty.criticalBattery, priority: 1200, module: nil))
        }

        if let d = s.disk, d.total > 0, d.available < lowDiskBytes || d.availableFraction < Threshold.lowDiskFraction {
            issues.append(HealthIssue(id: "out_of_disk_space", title: "Espace disque presque épuisé",
                                      detail: "Il ne reste que \(FileSizer.format(d.available)) sur le disque de démarrage.",
                                      severity: .warning, penalty: Penalty.lowDisk, priority: 1000, module: "junk"))
        }

        let m = s.memory
        if m.pressure == .critical || (m.pressure == .warning && m.swapFraction > Threshold.swapFraction) {
            issues.append(HealthIssue(id: "low_ram", title: "Mémoire fortement sollicitée",
                                      detail: "La mémoire vive et le swap sont presque pleins. Quittez les apps inutilisées.",
                                      severity: m.pressure == .critical ? .critical : .warning, penalty: Penalty.lowMemory,
                                      priority: 900, module: "performance"))
        }

        if let t = s.trashSize, t > trashBytes {
            issues.append(HealthIssue(id: "trash_bin_overfill", title: "Videz votre corbeille",
                                      detail: "La corbeille occupe \(FileSizer.format(t)).",
                                      severity: .info, penalty: Penalty.trash, priority: 450, module: "junk"))
        }

        if s.uptime > Threshold.uptime {
            let days = Int(s.uptime / 86_400)
            issues.append(HealthIssue(id: "uptime", title: "Redémarrez votre Mac",
                                      detail: "Votre Mac n'a pas redémarré depuis \(days) jours. Redémarrez-le de temps en temps.",
                                      severity: .info, penalty: Penalty.uptime, priority: 100, module: nil))
        }

        if let t = s.battery?.temperatureCelsius, t > BatteryInfo.hotTemperatureCelsius {
            issues.append(HealthIssue(id: "battery_temperature", title: "Batterie chaude",
                                      detail: "La batterie est à \(Int(t)) °C. Évitez les sources de chaleur.",
                                      severity: .warning, penalty: Penalty.hotBattery, priority: 50, module: nil))
        }

        self.init(issues: issues)
    }

    /// Score and order of a given list of active factors.
    public init(issues: [HealthIssue]) {
        self.issues = issues.sorted { $0.priority > $1.priority }
        score = max(0, Self.maxScore - issues.reduce(0) { $0 + $1.penalty })
        status = HealthStatus(score: score)
    }

    static func recencyIssues(scans: [String: Date], deep: Date?, vibeCheckInterval: TimeInterval, now: Date) -> [HealthIssue] {
        func stale(_ date: Date?, _ window: TimeInterval) -> Bool { date.map { now.timeIntervalSince($0) > window } ?? true }
        var out: [HealthIssue] = []
        let vibeCheckStale = stale(scans["vibecheck"], vibeCheckInterval)
        if vibeCheckStale {
            out.append(HealthIssue(id: "no_vibe_check_recently", title: "Il est temps de prendre soin de votre Mac",
                                   detail: scans["vibecheck"] == nil ? "Vous n'avez pas encore lancé Vibe Check." : "Votre dernier Vibe Check date un peu.",
                                   severity: .info, penalty: Penalty.noVibeCheck, priority: 300, module: "vibecheck"))
        }
        for (i, f) in recencyFactors.enumerated() where stale(scans[f.module], Recency.module) {
            if vibeCheckStale && vibeCheckModules.contains(f.module) { continue }
            out.append(HealthIssue(id: f.id, title: f.title,
                                   detail: scans[f.module] == nil ? "Ce module n'a encore jamais été lancé." : "Pas d'analyse depuis plus de deux semaines.",
                                   severity: .info, penalty: Penalty.noModuleScan, priority: 250 - i, module: f.module))
        }
        if stale(deep, Recency.deepScan) {
            out.append(HealthIssue(id: "no_deep_scan_recently", title: "Analyse approfondie recommandée",
                                   detail: "Choisissez le mode Approfondi dans Réglages > Analyse, puis lancez Protection.",
                                   severity: .info, penalty: Penalty.noDeepScan, priority: 800, module: "protection"))
        }
        return out
    }
}
