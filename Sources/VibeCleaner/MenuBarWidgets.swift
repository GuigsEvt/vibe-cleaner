import SwiftUI
import VibeCleanerCore

// Widgets of the menu grid. Each one is a glass tile; a click opens its detail sheet.

struct StorageWidget: View {
    let monitor: MonitorModel
    let open: (String) -> Void
    let emptyTrash: () -> Void
    let busy: Bool

    var body: some View {
        if let d = monitor.snapshot.disk {
            let usedFraction = 1 - d.availableFraction
            MenuTile(title: "Stockage", symbol: "internaldrive.fill", tint: MenuTint.storage,
                     summary: "\(FileSizer.format(d.available)) libres sur \(FileSizer.format(d.total))") {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(FileSizer.format(d.available)).font(.title2.bold()).monospacedDigit()
                    Text("libres sur \(FileSizer.format(d.total))").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("\(Int((usedFraction * 100).rounded())) %").font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(usedFraction > 0.9 ? Theme.critical : .secondary)
                }
                SegmentedBar(segments: StorageDetail.segments(disk: d, storage: monitor.storage), total: Double(d.total), height: 8)
                if monitor.drive == .failing {
                    Label("Disque défaillant : sauvegardez vos données", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.critical)
                }
            } detail: {
                StorageDetail(monitor: monitor, disk: d, emptyTrash: emptyTrash, busy: busy, open: open)
            }
        }
    }
}

struct MemoryWidget: View {
    let memory: MemoryUsage
    let history: [Double]
    let open: (String) -> Void
    let freeRAM: () -> Void
    let busy: Bool
    let hogs: [ProcessUsage]
    let quit: (ProcessTarget) -> Void

    var body: some View {
        let m = memory
        let pr = MemoryDetail.pressure(m.pressure)
        let fraction = m.total > 0 ? Double(m.used) / Double(m.total) : 0
        MenuTile(title: "Mémoire", symbol: "memorychip.fill", tint: MenuTint.memory,
                 summary: "\(FileSizer.format(m.used)) utilisés sur \(FileSizer.format(m.total)), pression \(pr.title.lowercased())") {
            HStack(alignment: .center, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text(FileSizer.format(m.used)).font(.title2.bold()).monospacedDigit()
                        Text("/ \(FileSizer.format(m.total))").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: DS.Space.xs) {
                        StatusPill(title: "Pression \(pr.title.lowercased())", tint: pr.color)
                        if m.swapUsed > 0 { Text("Swap \(FileSizer.format(m.swapUsed))").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
                if history.count >= 2 {
                    Sparkline(values: history, tint: MenuTint.memory, domain: 0...100).frame(height: 40)
                } else {
                    MenuRing(value: fraction, tint: MenuTint.memory, lineWidth: 5) { EmptyView() }.frame(width: 40, height: 40)
                }
            }
        } detail: {
            MemoryDetail(memory: m, history: history, busy: busy, hogs: hogs, free: freeRAM, open: open, quit: quit)
        }
    }
}

struct CPUWidget: View {
    let snapshot: SystemSnapshot
    let history: MonitorHistory
    let processes: [ProcessUsage]
    let quit: (ProcessTarget) -> Void

    var body: some View {
        let c = snapshot.cpu
        MenuTile(title: "Processeur", symbol: "cpu.fill", tint: MenuTint.cpu, summary: "\(Int(c.total)) % d'utilisation, température \(snapshot.thermal.title.lowercased())") {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(c.total))").font(.title2.bold()).monospacedDigit()
                Text("%").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if snapshot.thermal > .nominal {
                    Image(systemName: "thermometer.high").font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.thermal >= .serious ? Theme.warningText : .secondary)
                        .help("Température \(snapshot.thermal.title.lowercased())")
                }
            }
            Group {
                if history.cpuUser.count >= 2 {
                    Sparkline(values: history.cpuTotal, tint: MenuTint.cpu, domain: 0...100)
                } else {
                    CapsuleBar(fraction: c.total / 100, tint: MenuTint.cpu).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 26)
        } detail: {
            CPUDetail(snapshot: snapshot, user: history.cpuUser.values, total: history.cpuTotal, processes: processes, quit: quit)
        }
    }
}

struct BatteryWidget: View {
    let battery: BatteryInfo
    let history: [Double]

    var body: some View {
        let p = BatteryPresentation(battery: battery)
        MenuTile(title: "Batterie", symbol: p.symbol, tint: p.tint, summary: "\(battery.percent) %, \(p.state)") {
            HStack(spacing: DS.Space.s) {
                MenuRing(value: Double(battery.percent) / 100, tint: p.tint, lineWidth: 5) {
                    Image(systemName: p.sourceSymbol).font(.system(size: 10, weight: .bold)).foregroundStyle(p.tint)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(battery.percent)").font(.title2.bold()).monospacedDigit()
                        Text("%").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(battery.isCharging || battery.isPluggedIn ? p.source : battery.minutesRemaining.map { "\(BatteryPresentation.format($0)) restantes" } ?? p.source)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                }
            }
        } detail: {
            BatteryDetail(battery: battery, history: history)
        }
    }
}

struct NetworkWidget: View {
    let network: NetworkUsage
    let history: MonitorHistory

    var body: some View {
        let p = NetworkPresentation(network: network)
        MenuTile(title: "Réseau", symbol: p.symbol, tint: MenuTint.network,
                 summary: "\(p.name), descendant \(NetworkPresentation.rate(network.bytesInPerSecond)), montant \(NetworkPresentation.rate(network.bytesOutPerSecond))") {
            VStack(alignment: .leading, spacing: 0) {
                rate("arrow.down", network.bytesInPerSecond, MenuTint.network, bold: true)
                HStack(spacing: 3) {
                    rate("arrow.up", network.bytesOutPerSecond, MenuTint.upload, bold: false)
                    Text("· \(p.name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Group {
                if history.networkIn.count >= 2 {
                    Sparkline(values: history.networkIn.values, tint: MenuTint.network)
                } else {
                    Color.clear
                }
            }
            .frame(height: 18)
        } detail: {
            NetworkDetail(network: network, download: history.networkIn.values, upload: history.networkOut.values)
        }
    }

    private func rate(_ symbol: String, _ value: Double, _ tint: Color, bold: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(NetworkPresentation.rate(value)).font(bold ? .headline : .caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct ProtectionWidget: View {
    let open: (String) -> Void
    /// Sample date, so the scan history is read again at each refresh.
    let refreshed: Date
    let xprotect: XProtectStatus?
    @AppStorage(MonitorKeys.protectionMonitorEnabled) private var monitorOn = true

    var body: some View {
        let s = ProtectionState.read(monitorOn: monitorOn, xprotect: xprotect)
        MenuTile(title: "Protection", symbol: s.symbol, tint: s.threats > 0 ? Theme.critical : MenuTint.protection,
                 summary: "\(s.title), surveillance \(monitorOn ? "activée" : "désactivée")") {
            HStack(spacing: DS.Space.s) {
                Image(systemName: s.symbol).font(.system(size: 24)).foregroundStyle(s.color.gradient)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    Text(s.xprotectLine ?? "Surveillance \(monitorOn ? "activée" : "désactivée")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxHeight: .infinity)
        } detail: {
            ProtectionDetail(state: s, monitorOn: $monitorOn, open: open)
        }
    }
}

struct DevicesWidget: View {
    let devices: [PeripheralBattery]

    var body: some View {
        let low = devices.filter { $0.percent < AlertSettings.accessoryLowPercent }
        MenuTile(title: "Appareils", symbol: "keyboard.fill", tint: MenuTint.devices,
                 summary: "\(devices.count) appareil(s)" + (low.isEmpty ? "" : ", batterie faible : " + low.map(\.name).joined(separator: ", "))) {
            HStack(spacing: DS.Space.m) {
                ForEach(devices.prefix(3)) { d in
                    let low = d.percent < AlertSettings.accessoryLowPercent
                    HStack(spacing: DS.Space.xs) {
                        MenuRing(value: Double(d.percent) / 100, tint: low ? Theme.critical : MenuTint.devices, lineWidth: 3) {
                            Image(systemName: d.symbol).font(.system(size: 9, weight: .semibold))
                        }
                        .frame(width: 28, height: 28)
                        Text("\(d.percent) %").font(.callout.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(low ? Theme.warningText : .primary)
                    }
                }
                Spacer(minLength: 0)
            }
            if !low.isEmpty {
                Text("Batterie faible : " + low.map(\.name).joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Theme.warningText).lineLimit(1)
            }
        } detail: {
            DevicesDetail(devices: devices)
        }
    }
}

/// External volumes with their Eject button (no detail sheet, as before).
struct DisksWidget: View {
    let volumes: [ExternalVolume]
    let eject: (ExternalVolume) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                TileIcon(symbol: "externaldrive.fill", tint: MenuTint.disks, size: 22)
                Text("Disques externes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(volumes) { v in
                HStack(spacing: DS.Space.s) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(v.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer(minLength: DS.Space.xs)
                            Text("\(FileSizer.format(v.available)) libres" + (v.isReadOnly ? " (lecture seule)" : ""))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        let f = v.total > 0 ? 1 - Double(v.available) / Double(v.total) : 0
                        CapsuleBar(fraction: f, tint: MenuTint.level(f, base: MenuTint.disks), height: 5)
                    }
                    ConfirmButton(confirmHelp: "Cliquez encore pour éjecter \(v.name).", action: { eject(v) }) {
                        if $0 { Text("Éjecter") } else { Image(systemName: "eject.fill").font(.system(size: 11, weight: .semibold)) }
                    }
                    .accessibilityLabel("Éjecter \(v.name)")
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(tint: MenuTint.disks)
    }
}

/// Hungry apps of the panel, each with Quit when allowed.
struct ProcessesCard: View {
    let processes: [ProcessUsage]
    let quit: (ProcessTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                TileIcon(symbol: "flame.fill", tint: MenuTint.cpu, size: 22)
                Text("Apps gourmandes").font(.caption.weight(.semibold)).foregroundStyle(.secondary).layoutPriority(1)
                Spacer(minLength: 0)
                Text("CPU").frame(width: 40, alignment: .trailing)
                Text("Mémoire").frame(width: 62, alignment: .trailing)
                Color.clear.frame(width: ProcessRow.actionWidth, height: 1)
            }
            .font(.caption2).foregroundStyle(.tertiary)
            ForEach(processes) { ProcessRow(process: $0, quit: quit) }
        }
        .lineSpacing(0)
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass()
    }
}
