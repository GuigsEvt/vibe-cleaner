import Foundation

/// Guide helpers around `HealthAssessment`: skips, menu badge, "En savoir plus", debug simulation.
public enum Guide {
    /// Text of the score's info popover.
    public static let scoreExplanation = "Nous estimons la santé de votre Mac d'après l'espace disque, les menaces potentielles, l'état de la batterie, la charge moyenne et bien d'autres choses."
    public static let emptyTitle = "Aucune recommandation"
    public static let emptyDetail = "Rien à faire aujourd'hui. Votre Mac va très bien."

    /// Recommendations not skipped (or whose skip has expired), still sorted by priority.
    public static func visible(_ issues: [HealthIssue], skipped: [String: Date], now: Date = Date()) -> [HealthIssue] {
        issues.filter { (skipped[$0.id] ?? .distantPast) <= now }
    }

    /// The menu's "Recommandation du jour": the highest-priority visible one.
    public static func today(_ issues: [HealthIssue], skipped: [String: Date], now: Date = Date()) -> HealthIssue? {
        visible(issues, skipped: skipped, now: now).first
    }

    /// Menu bar badge: the worst severity among warnings and criticals, and how many there are; nil when none.
    public static func badge(_ issues: [HealthIssue]) -> (severity: IssueSeverity, count: Int)? {
        let serious = issues.filter { $0.severity >= .warning }
        guard let worst = serious.map(\.severity).max() else { return nil }
        return (worst, serious.count)
    }

    /// Longer text of the "En savoir plus" popover.
    public static func explanation(_ id: String) -> String {
        switch id {
        case "malware_detected": "La dernière analyse Protection a trouvé des éléments malveillants ou suspects. Ouvrez Protection pour les examiner et les mettre en quarantaine."
        case "critical_drive_health": "Le disque signale lui-même une défaillance (état SMART). Il peut cesser de fonctionner à tout moment : sauvegardez vos données avec Time Machine sans attendre."
        case "critical_battery_health": "Une batterie usée tient moins longtemps et peut faire ralentir le Mac. Consultez Réglages Système > Batterie et envisagez un remplacement."
        case "no_fda": "L'accès complet au disque permet d'analyser les caches, la messagerie, la corbeille et les dossiers protégés. Sans lui, une partie du Mac reste hors de portée."
        case "disabled_menu": "Le menu affiche en permanence l'espace disque, la mémoire, le processeur et les alertes. Réactivez-le pour garder un œil sur votre Mac."
        case "malware_monitor_off": "La surveillance vérifie régulièrement les emplacements où les logiciels malveillants s'installent. Désactivée, seules les analyses manuelles vous protègent."
        case "no_deep_scan_recently": "Le mode Approfondi analyse aussi le Bureau, les Documents et la Bibliothèque. Il est plus lent, mais trouve ce que les modes rapides laissent passer. Une fois par mois suffit."
        case "unused_apps": "Les apps que vous n'ouvrez plus occupent de la place et laissent parfois des agents en arrière-plan. Désinstallez-les avec leurs fichiers liés."
        case "out_of_disk_space": "Sous quelques Go libres, macOS ne peut plus créer de mémoire virtuelle ni installer de mises à jour. Libérez de l'espace avec le Nettoyage ou le Fouillis."
        case "low_ram": "Quand la mémoire et le swap sont presque pleins, le Mac ralentit. Quittez les apps que vous n'utilisez pas ou ouvrez Performance."
        case "trash_bin_overfill": "Les fichiers de la corbeille occupent toujours de la place sur le disque tant qu'elle n'est pas vidée."
        case "uptime": "Redémarrer de temps en temps vide les caches de la mémoire, termine les processus bloqués et applique les mises à jour en attente."
        case "battery_temperature": "Une batterie chaude s'use plus vite. Évitez le soleil direct et les surfaces molles qui gênent la ventilation."
        case "no_vibe_check_recently": "Vibe Check enchaîne le nettoyage, la protection, la performance, les applications et le fouillis en un seul clic."
        default: "Une analyse régulière de ce module garde votre Mac propre et rapide."
        }
    }

    /// Every factor id the debug panel can force.
    public static let factorIDs: [String] = ["malware_detected", "critical_drive_health", "critical_battery_health", "no_fda", "disabled_menu",
                                             "no_deep_scan_recently", "malware_monitor_off", "unused_apps", "out_of_disk_space", "low_ram",
                                             "trash_bin_overfill", "no_vibe_check_recently", "uptime", "battery_temperature"]
        + HealthAssessment.recencyFactors.map(\.id)

    /// The issue a factor produces, built through the real rules with forged inputs. Display only (debug simulation).
    public static func sample(_ id: String) -> HealthIssue? {
        let gb: Int64 = 1_000_000_000
        var s = SystemSnapshot(memory: MemoryUsage(total: 16 * gb), disk: DiskUsage(total: 500 * gb, available: 200 * gb))
        var f = HealthAssessment.Facts()
        switch id {
        case "malware_detected": f.threats = 2
        case "critical_drive_health": f.drive = .failing
        case "critical_battery_health": s.battery = BatteryInfo(percent: 50, healthPercent: 55)
        case "no_fda": f.hasFullDiskAccess = false
        case "disabled_menu": f.menuEnabled = false
        case "malware_monitor_off": f.malwareMonitorEnabled = false
        case "unused_apps": f.unusedApps = 4
        case "out_of_disk_space": s.disk = DiskUsage(total: 500 * gb, available: 4 * gb)
        case "low_ram": s.memory.pressure = .critical
        case "trash_bin_overfill": s.trashSize = 12 * gb
        case "uptime": s.uptime = 12 * 86_400
        case "battery_temperature": s.battery = BatteryInfo(percent: 50, healthPercent: 97, temperatureCelsius: 45)
        case "no_vibe_check_recently", "no_deep_scan_recently":
            f.lastScans = [:]
        default:
            guard HealthAssessment.recencyFactors.contains(where: { $0.id == id }) else { return nil }
            f.lastScans = ["vibecheck": f.now]
        }
        return HealthAssessment(snapshot: s, facts: f).issues.first { $0.id == id }
    }

    /// `base` with the forced factors added (or replaced); never stored, never acted upon.
    public static func simulate(_ base: HealthAssessment, forcing ids: Set<String>) -> HealthAssessment {
        let forced = ids.compactMap(sample)
        let kept = base.issues.filter { !ids.contains($0.id) }
        return HealthAssessment(issues: kept + forced)
    }
}
