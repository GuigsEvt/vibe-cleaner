import SwiftUI
import VibeCleanerCore

// Detail sheets opened from the menu widgets.

// MARK: - Battery

/// Texts and colours of the battery widget and its sheet.
struct BatteryPresentation {
    let battery: BatteryInfo

    static func format(_ minutes: Int) -> String { "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" }

    /// Full sentence, as before the redesign.
    var state: String {
        let b = battery
        if b.isCharging { return b.minutesRemaining.map { "\(Self.format($0)) avant la charge complète" } ?? "En charge" }
        if b.isPluggedIn { return b.percent >= 100 ? "Chargée, sur secteur" : "Sur secteur, pas en charge" }
        return b.minutesRemaining.map { "Environ \(Self.format($0)) restantes" } ?? "Calcul…"
    }

    /// Short source label: en charge / branché / sur batterie.
    var source: String { battery.isCharging ? "En charge" : battery.isPluggedIn ? "Branché" : "Sur batterie" }

    var sourceSymbol: String { battery.isCharging ? "bolt.fill" : battery.isPluggedIn ? "powerplug.fill" : "battery.75percent" }

    var low: Bool { battery.percent <= 20 && !battery.isPluggedIn }

    var tint: Color { low ? Theme.critical : MenuTint.battery }

    var symbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var health: (title: String, color: Color) {
        switch battery.healthLevel {
        case .perfect: ("Parfaite", Theme.healthy)
        case .normal: ("Normale", Theme.healthy)
        case .warning: ("À surveiller", Theme.warning)
        case .critical: ("Révision recommandée", Theme.critical)
        case .unknown: ("Non calculable", .secondary)
        }
    }
}

struct BatteryDetail: View {
    let battery: BatteryInfo
    let history: [Double]

    var body: some View {
        let p = BatteryPresentation(battery: battery)
        let b = battery
        DetailPanel(title: "Batterie", subtitle: "Batterie interne · \(p.source.lowercased())", symbol: p.symbol, tint: p.tint) {
            HStack(spacing: DS.Space.l) {
                MenuRing(value: Double(b.percent) / 100, tint: p.tint, lineWidth: 11) {
                    VStack(spacing: 0) {
                        if b.isCharging { Image(systemName: "bolt.fill").font(.caption.bold()).foregroundStyle(p.tint) }
                        Text("\(b.percent) %").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    StatusPill(title: p.source, tint: p.tint, symbol: p.sourceSymbol)
                    if let m = b.minutesRemaining {
                        Text(BatteryPresentation.format(m)).font(.title2.bold()).monospacedDigit()
                        Text(b.isCharging ? "avant la charge complète" : b.isPluggedIn ? "restantes" : "d'autonomie restante")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(b.isPluggedIn ? (b.percent >= 100 ? "Chargée" : "Pas en charge") : "Calcul…").font(.title3.bold())
                        Text(b.isPluggedIn ? "Alimenté par l'adaptateur secteur" : "macOS estime l'autonomie")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
            .glass(tint: p.tint)
            .accessibilityElement(children: .combine)
            .entrance(1)

            DetailCard(title: "Niveau pendant la session", tint: p.tint, index: 2) {
                HistoryChart(series: [.init(title: "Charge", values: history, color: p.tint)], domain: 0...100, height: 70)
            }

            DetailCard(title: "Santé", tint: p.health.color == .secondary ? nil : p.health.color, index: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(b.healthPercent.map { "\(Int($0)) %" } ?? "—").font(.title2.bold()).monospacedDigit()
                    Text("de capacité maximale").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(title: p.health.title, tint: p.health.color == .secondary ? .gray : p.health.color)
                }
                if let h = b.healthPercent { CapsuleBar(fraction: h / 100, tint: p.health.color) }
                Text("Par rapport à la capacité d'une batterie neuve.").font(.caption2).foregroundStyle(.secondary)
                if b.serviceRecommended {
                    Label("macOS recommande de faire réviser la batterie.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.critical)
                }
            }

            HStack(spacing: DS.Space.s) {
                MetricTile(title: "Cycles de charge", value: b.cycleCount.map { "\($0)" } ?? "—", wash: p.tint)
                if let t = b.temperatureCelsius {
                    let hot = t > BatteryInfo.hotTemperatureCelsius
                    MetricTile(title: "Température", value: "\(Int(t)) °C", note: hot ? "Chaude" : "Normale",
                               tint: hot ? Theme.warning : nil, wash: p.tint)
                } else {
                    MetricTile(title: "Température", value: "—", note: "Non lisible", wash: p.tint)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .entrance(4)
        }
    }
}

// MARK: - CPU

struct CPUDetail: View {
    let snapshot: SystemSnapshot
    let user: [Double]
    let total: [Double]
    let processes: [ProcessUsage]
    let quit: (ProcessTarget) -> Void

    var thermalColor: Color {
        switch snapshot.thermal {
        case .nominal: Theme.healthy
        case .fair: MenuTint.cpu
        case .serious: Theme.warning
        case .critical: Theme.critical
        }
    }

    var body: some View {
        let c = snapshot.cpu
        DetailPanel(title: "Processeur", subtitle: "\(c.coreCount) cœurs", symbol: "cpu", tint: MenuTint.cpu) {
            DetailCard(tint: MenuTint.cpu, index: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(c.total)) %").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("d'utilisation").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                // Total first, then the system share on top of it: reads as user stacked over system.
                HistoryChart(series: [.init(title: "Total", values: total, color: MenuTint.cpu),
                                      .init(title: "Système", values: total.indices.map { total[$0] - (user.indices.contains($0) ? user[$0] : 0) },
                                            color: MenuTint.cpuSystem)],
                             domain: 0...100, height: 84)
                HStack(spacing: DS.Space.l) {
                    LegendRow(color: MenuTint.cpu, title: "Utilisateur", value: "\(Int(c.user)) %")
                    LegendRow(color: MenuTint.cpuSystem, title: "Système", value: "\(Int(c.system)) %")
                }
            }

            HStack(spacing: DS.Space.s) {
                MetricTile(title: "Inactif", value: "\(Int(c.idle)) %", wash: MenuTint.cpu)
                MetricTile(title: "Allumé depuis",
                           value: Duration.seconds(snapshot.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
                                .locale(MenuTint.locale)), wash: MenuTint.cpu)
            }
            .fixedSize(horizontal: false, vertical: true)
            .entrance(2)

            DetailCard(tint: snapshot.thermal > .nominal ? thermalColor : nil, index: 3) {
                HStack(spacing: DS.Space.s) {
                    TileIcon(symbol: snapshot.thermal >= .serious ? "thermometer.high" : "thermometer.medium", tint: thermalColor, size: 26)
                    Text("Température").font(.callout.weight(.semibold))
                    Spacer()
                    StatusPill(title: snapshot.thermal.title, tint: thermalColor)
                }
                Text(snapshot.thermal.detail).font(.caption)
                    .foregroundStyle(snapshot.thermal >= .serious ? Theme.warningText : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("État thermique de macOS : la température exacte des capteurs n'est pas lisible sans API privée.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            if !processes.isEmpty {
                DetailCard(title: "Apps gourmandes", index: 4) {
                    ForEach(processes.sorted { $0.cpuPercent > $1.cpuPercent }) { ProcessRow(process: $0, showsMemory: false, quit: quit) }
                }
            }
        }
    }
}

// MARK: - Memory

struct MemoryDetail: View {
    let memory: MemoryUsage
    let history: [Double]
    let busy: Bool
    let hogs: [ProcessUsage]
    let free: () -> Void
    let open: (String) -> Void
    let quit: (ProcessTarget) -> Void

    static func pressure(_ p: MemoryPressure) -> (title: String, detail: String, color: Color) {
        switch p {
        case .normal: ("Normale", "Votre Mac est prêt à prendre en charge d'autres tâches.", Theme.healthy)
        case .warning: ("Élevée", "Pensez à quitter les applications peu importantes.", Theme.warning)
        case .critical: ("Critique", "La mémoire est saturée : quittez des applications pour éviter les ralentissements.", Theme.critical)
        }
    }

    /// Tooltip of "Libérer la RAM": what `purge` does, and when it is worth it.
    static func freeRAMHelp(_ p: MemoryPressure) -> String {
        let now = switch p {
        case .normal: "La pression est normale : inutile de le faire maintenant, macOS gère déjà sa mémoire."
        case .warning, .critical: "La pression est élevée : cela peut soulager le Mac pendant un moment."
        }
        return "Vide le cache de fichiers que macOS garde en mémoire (commande purge, mot de passe requis). "
            + "Ne ferme aucune app et ne supprime rien. \(now) Le soulagement est temporaire : "
            + "pour libérer vraiment de la mémoire, mieux vaut quitter une app gourmande."
    }

    static func segments(_ m: MemoryUsage) -> [BarSegment] {
        [BarSegment(title: "Apps", value: Double(m.app), color: MenuTint.palette[1]),
         BarSegment(title: "Câblée", value: Double(m.wired), color: MenuTint.palette[2]),
         BarSegment(title: "Compressée", value: Double(m.compressed), color: MenuTint.palette[0]),
         BarSegment(title: "Fichiers en cache", value: Double(min(m.cache, m.available)), color: MenuTint.palette[3].opacity(0.55))]
    }

    var body: some View {
        let m = memory
        let pr = Self.pressure(m.pressure)
        DetailPanel(title: "Mémoire", subtitle: "\(FileSizer.format(m.total)) au total", symbol: "memorychip", tint: MenuTint.memory, width: 400) {
            DetailCard(tint: MenuTint.memory, index: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FileSizer.format(m.used)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("utilisés").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(title: "Pression \(pr.title.lowercased())", tint: pr.color)
                }
                HistoryChart(series: [.init(title: "Mémoire utilisée", values: history, color: MenuTint.memory)], domain: 0...100, height: 70)
                Text(pr.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            DetailCard(title: "Répartition", index: 2) {
                SegmentedBar(segments: Self.segments(m), total: Double(m.total), height: 12)
                ForEach(Self.segments(m)) { s in
                    LegendRow(color: s.color, title: s.title == "Câblée" ? "Câblée (réservée)" : s.title,
                              value: FileSizer.format(Int64(s.title == "Fichiers en cache" ? m.cache : Int64(s.value))))
                }
                LegendRow(color: Color.primary.opacity(0.15), title: "Disponible", value: FileSizer.format(m.available))
            }

            if !hogs.isEmpty {
                DetailCard(title: "Apps les plus gourmandes", index: 3) {
                    ForEach(hogs) { ProcessRow(process: $0, showsCPU: false, quit: quit) }
                }
            }

            DetailCard(title: "Swap", index: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FileSizer.format(m.swapUsed)).font(.title3.bold()).monospacedDigit()
                    Text("sur \(FileSizer.format(m.swapTotal))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                CapsuleBar(fraction: m.swapFraction, tint: MenuTint.level(m.swapFraction, base: MenuTint.memory))
                Text("Zone du disque qui aide macOS à gérer la mémoire quand elle se remplit.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DS.Space.s) {
                ConfirmButton(tint: MenuTint.memory, prominent: true, help: Self.freeRAMHelp(m.pressure), confirmHelp: "Cliquez encore pour libérer la mémoire inactive (mot de passe requis).", action: free) {
                    Label($0 ? "Confirmer" : "Libérer la RAM", systemImage: $0 ? "checkmark" : "wind").frame(maxWidth: .infinity)
                }
                .disabled(busy)
                Button { open("performance") } label: { Label("Optimiser", systemImage: "gauge.with.dots.needle.67percent").frame(maxWidth: .infinity) }
                    .buttonStyle(GlassButtonStyle())
            }
            .entrance(5)
        }
    }
}

// MARK: - Storage

struct StorageDetail: View {
    let monitor: MonitorModel
    let disk: DiskUsage
    let emptyTrash: () -> Void
    let busy: Bool
    let open: (String) -> Void

    /// Categories when they were computed, otherwise used and purgeable space.
    static func segments(disk d: DiskUsage, storage: StorageBreakdown?) -> [BarSegment] {
        if let s = storage {
            return s.parts.enumerated().map {
                BarSegment(title: $1.title, value: Double($1.bytes), color: $1.title == "Autres" ? MenuTint.other : MenuTint.palette[$0 % MenuTint.palette.count])
            }
        }
        return [BarSegment(title: "Utilisé", value: Double(d.used), color: MenuTint.storage),
                BarSegment(title: "Purgeable", value: Double(d.purgeable), color: MenuTint.storage.opacity(0.4))]
    }

    var body: some View {
        let d = disk
        let segments = Self.segments(disk: d, storage: monitor.storage)
        DetailPanel(title: "Stockage", subtitle: "Disque de démarrage · \(FileSizer.format(d.total))", symbol: "internaldrive.fill", tint: MenuTint.storage) {
            DetailCard(tint: MenuTint.storage, index: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(FileSizer.format(d.available)).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("disponibles").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                SegmentedBar(segments: segments, total: Double(d.total), height: 14)
                ForEach(segments) { LegendRow(color: $0.color, title: $0.title, value: FileSizer.format(Int64($0.value))) }
                LegendRow(color: Color.primary.opacity(0.15), title: monitor.storage == nil ? "Libre" : "Disponible",
                          value: FileSizer.format(monitor.storage == nil ? max(0, d.available - d.purgeable) : d.available))
                if let s = monitor.storage {
                    Text("Calculé \(MenuTint.relative(s.date))").font(.caption2).foregroundStyle(.secondary)
                } else if monitor.storageBusy {
                    HStack(spacing: DS.Space.s) { ProgressView().controlSize(.small); Text("Calcul des catégories…").font(.caption) }
                } else if !Permissions.hasFullDiskAccess {
                    Text("Accordez l'accès complet au disque pour voir le détail par catégorie.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            DetailCard(index: 2) {
                Line("Capacité", FileSizer.format(d.total))
                Line("Utilisé", FileSizer.format(d.used))
                Line("Disponible", FileSizer.format(d.available))
                Line("Dont purgeable", FileSizer.format(d.purgeable))
            }

            DetailCard(index: 3) {
                HStack(spacing: DS.Space.s) {
                    TileIcon(symbol: "trash.fill", tint: Theme.accent("junk"), size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Corbeille").font(.callout.weight(.semibold))
                        Text(monitor.snapshot.trashSize.map(FileSizer.format) ?? "Illisible").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    ConfirmButton(help: monitor.snapshot.trashSize == 0 ? "La corbeille est vide." : "",
                                  confirmHelp: "Cliquez encore : les fichiers de la corbeille seront supprimés pour de bon.", action: emptyTrash) {
                        Text($0 ? "Confirmer" : "Vider")
                    }
                    .disabled(busy || monitor.snapshot.trashSize == 0)
                    .accessibilityLabel("Vider la corbeille")
                }
            }

            DetailCard(tint: monitor.drive == .failing ? Theme.critical : nil, index: 4) {
                HStack(spacing: DS.Space.s) {
                    TileIcon(symbol: monitor.drive == .failing ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                             tint: monitor.drive == .failing ? Theme.critical : Theme.healthy, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Santé du disque (SMART)").font(.callout.weight(.semibold))
                        Text(monitor.drive.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(monitor.drive.detail).font(.caption).foregroundStyle(monitor.drive == .failing ? Theme.critical : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { open("vibecheck") } label: { Text("Lancer Vibe Check").frame(maxWidth: .infinity) }
                .buttonStyle(GlassButtonStyle(tint: MenuTint.brand, prominent: true))
                .entrance(5)
        }
    }
}

// MARK: - Network

struct NetworkPresentation {
    let network: NetworkUsage

    var name: String {
        switch network.kind {
        case .wifi: network.wifiName ?? "Wi-Fi"
        default: network.kind.title
        }
    }

    var symbol: String { network.kind == .wifi ? "wifi" : network.kind == .offline ? "wifi.slash" : "network" }

    static func rate(_ bytesPerSecond: Double) -> String { "\(FileSizer.format(Int64(bytesPerSecond)))/s" }
}

struct NetworkDetail: View {
    let network: NetworkUsage
    let download: [Double]
    let upload: [Double]
    @State private var testing = false
    @State private var result: SpeedTestResult?
    @State private var failed = false

    var body: some View {
        let p = NetworkPresentation(network: network)
        DetailPanel(title: "Réseau", subtitle: p.name, symbol: p.symbol, tint: MenuTint.network) {
            DetailCard(tint: MenuTint.network, index: 1) {
                HStack(spacing: DS.Space.l) {
                    rate("Descendant", "arrow.down.circle.fill", network.bytesInPerSecond, MenuTint.network)
                    rate("Montant", "arrow.up.circle.fill", network.bytesOutPerSecond, MenuTint.upload)
                    Spacer(minLength: 0)
                }
                HistoryChart(series: [.init(title: "Descendant", values: download, color: MenuTint.network),
                                      .init(title: "Montant", values: upload, color: MenuTint.upload)],
                             format: { NetworkPresentation.rate($0) }, showsScale: true, height: 76)
            }

            DetailCard(title: "Connexion", index: 2) {
                Line("Type de connexion", network.kind.title)
                if network.kind == .wifi {
                    Line("Nom", network.wifiName ?? "Masqué")
                    if network.wifiName == nil {
                        Text("macOS ne donne le nom du réseau qu'aux apps autorisées à la localisation ; Vibe Cleaner ne la demande pas.")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let sec = network.wifiSecurity {
                        Line("Sécurité", sec.label)
                        Text(sec.advice).font(.caption).foregroundStyle(sec.level <= .weak ? Theme.warningText : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if network.kind == .wired {
                    Text("La connexion physique à votre routeur offre un bon niveau de sécurité.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            DetailCard(title: "Test de débit", index: 3) {
                if let r = result {
                    HStack(spacing: DS.Space.s) {
                        MetricTile(title: "Descendant", value: String(format: "%.0f Mb/s", r.download), wash: MenuTint.network)
                        MetricTile(title: "Montant", value: String(format: "%.0f Mb/s", r.upload), wash: MenuTint.network)
                        if let rtt = r.rtt { MetricTile(title: "Latence", value: String(format: "%.0f ms", rtt), wash: MenuTint.network) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Text(r.goodFor.isEmpty ? "La connexion est très lente." : "Convient pour : " + r.goodFor.joined(separator: ", "))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if failed { Text("Le test n'a pas abouti.").font(.caption).foregroundStyle(Theme.warningText) }
                HStack(spacing: DS.Space.s) {
                    Button { test() } label: { Label(testing ? "Test en cours…" : "Tester le débit", systemImage: "speedometer") }
                        .buttonStyle(GlassButtonStyle(tint: MenuTint.network, prominent: true))
                        .disabled(testing || network.kind == .offline)
                    if testing { ProgressView().controlSize(.small) }
                }
                Text("Utilise l'outil networkQuality d'Apple, qui télécharge et envoie des données de test vers les serveurs d'Apple.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rate(_ title: String, _ symbol: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(NetworkPresentation.rate(value)).font(.headline).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func test() {
        testing = true
        failed = false
        Task {
            let r = await Task.detached { SpeedTestResult.run() }.value
            result = r ?? result
            failed = r == nil
            testing = false
        }
    }
}

// MARK: - Protection

struct ProtectionState {
    /// Sure detections (XProtect rule or known hash).
    let threats: Int
    /// Heuristic findings not accepted by the user.
    let toReview: Int
    let last: Date?
    let monitorOn: Bool
    /// The malware scanner built into macOS; nil when unreadable.
    var xprotect: XProtectStatus?

    static func read(monitorOn: Bool, xprotect: XProtectStatus?) -> ProtectionState {
        let d = UserDefaults.standard
        return ProtectionState(threats: d.stringArray(forKey: Prefs.threatIDs)?.count ?? 0,
                               toReview: Set(d.stringArray(forKey: Prefs.reviewIDs) ?? []).subtracting(RiskAcceptance.stored).count,
                               last: ScanHistory.last("protection"), monitorOn: monitorOn, xprotect: xprotect)
    }

    var title: String {
        threats > 0 ? "\(threats) menace(s)" : toReview > 0 ? "\(toReview) à vérifier" : last == nil && xprotect?.isActive != true ? "Jamais analysé" : "Protégé"
    }
    var symbol: String { threats > 0 ? "exclamationmark.shield.fill" : toReview > 0 ? "questionmark.diamond.fill" : "checkmark.shield.fill" }
    var color: Color {
        threats > 0 ? Theme.critical : toReview > 0 || !monitorOn || (last == nil && xprotect?.isActive != true) ? Theme.warningText : Theme.healthy
    }
    var message: String {
        threats > 0 ? "Des éléments malveillants attendent votre décision."
            : toReview > 0 ? "Des éléments inhabituels méritent un coup d'œil. Ce ne sont pas forcément des menaces."
            : "Aucune menace connue sur ce Mac."
    }
    /// "XProtect d'Apple : actif · règles 5368" for the widget and the sheet.
    var xprotectLine: String? {
        guard let x = xprotect else { return nil }
        return x.isActive ? "XProtect actif" + (x.version.map { " · règles \($0)" } ?? "") : "XProtect partiellement désactivé"
    }
}

struct ProtectionDetail: View {
    let state: ProtectionState
    @Binding var monitorOn: Bool
    let open: (String) -> Void

    var body: some View {
        let s = state
        DetailPanel(title: "Protection", subtitle: "Surveillance \(monitorOn ? "activée" : "désactivée")",
                    symbol: s.symbol, tint: s.threats > 0 ? Theme.critical : MenuTint.protection) {
            DetailCard(tint: s.color, index: 1) {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: s.symbol).font(.system(size: 40)).foregroundStyle(s.color.gradient).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.title3.bold())
                        Text(s.message)
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DetailCard(index: 2) {
                Line("Dernière analyse", s.last.map(MenuTint.relative) ?? "Jamais")
                Line("Menaces trouvées", "\(s.threats)")
                if s.toReview > 0 { Line("Éléments à vérifier", "\(s.toReview)") }
                Line("Surveillance", monitorOn ? "Activée" : "Désactivée")
            }
            if let x = s.xprotect {
                DetailCard(index: 2) {
                    HStack(spacing: DS.Space.s) {
                        TileIcon(symbol: "apple.logo", tint: x.isActive ? Theme.healthy : Theme.warning, size: 26)
                        Text("XProtect d'Apple").font(.callout.weight(.semibold))
                        Spacer()
                        StatusPill(title: x.isActive ? "Actif" : "Partiel", tint: x.isActive ? Theme.healthy : Theme.warning)
                    }
                    if let v = x.version { Line("Version des règles", v) }
                    if let d = x.installed { Line("Mises à jour", MenuTint.relative(d)) }
                    Line("Au lancement des apps", x.launchScans ? "Activée" : "Désactivée")
                    Line("En arrière-plan", x.backgroundScans ? "Activée" : "Désactivée")
                    Text("L'antivirus intégré à macOS : il vérifie les apps à leur ouverture et supprime seul les malwares connus. Vibe Cleaner le complète.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Space.s) {
                if !monitorOn { Button("Activer") { monitorOn = true }.buttonStyle(GlassButtonStyle()) }
                Button { open("protection") } label: {
                    Label(s.threats > 0 ? "Examiner et supprimer" : s.toReview > 0 ? "Examiner" : "Analyser",
                          systemImage: "shield.lefthalf.filled").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(tint: s.threats > 0 ? Theme.critical : MenuTint.protection, prominent: true))
            }
            .entrance(3)
        }
    }
}

// MARK: - Devices

struct DevicesDetail: View {
    let devices: [PeripheralBattery]

    var body: some View {
        DetailPanel(title: "Appareils connectés", subtitle: "\(devices.count) accessoire(s)", symbol: "keyboard.fill", tint: MenuTint.devices) {
            DetailCard(index: 1) {
                ForEach(devices) { d in
                    let low = d.percent < AlertSettings.accessoryLowPercent
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack(spacing: DS.Space.s) {
                            TileIcon(symbol: d.symbol, tint: low ? Theme.critical : MenuTint.devices, size: 24)
                            Text(d.name).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(d.percent) %").font(.callout.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(low ? Theme.warningText : .primary)
                        }
                        CapsuleBar(fraction: Double(d.percent) / 100, tint: low ? Theme.critical : MenuTint.devices, height: 5)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Accessoires qui publient leur batterie (claviers, souris, trackpads). Les AirPods n'y figurent pas.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                .entrance(2)
        }
    }
}
