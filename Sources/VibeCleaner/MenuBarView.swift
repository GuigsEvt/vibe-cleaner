import SwiftUI
import VibeCleanerCore

/// Live readings for the menu bar, its badge and the Guide. Samples every 2 s while the menu is open,
/// every 30 s otherwise.
@MainActor @Observable
final class MonitorModel {
    var snapshot = SystemSnapshot()
    var health: HealthAssessment?
    var processes: [ProcessUsage] = []
    /// Top memory users, for the memory sheet.
    var memoryHogs: [ProcessUsage] = []
    var drive: DriveHealth = .unknown
    var accessories: [PeripheralBattery] = []
    var volumes: [ExternalVolume] = []
    var storage: StorageBreakdown?
    var storageBusy = false
    var mac: MacModel?
    /// macOS's own malware scanner, read once an hour.
    var xprotect: XProtectStatus?
    /// Recent readings for the widget charts.
    var history = MonitorHistory()
    /// Set by the menu window while it is shown.
    var visible = false
    var skipped: [String: Date] = Prefs.guideSkips
    private(set) var sampled = false
    private let sampler = SystemSampler()
    private var task: Task<Void, Never>?
    private var last: [String: Date] = [:]

    static let storageInterval: TimeInterval = 30 * 60

    /// Recommendations not skipped, highest priority first.
    var recommendations: [HealthIssue] { Guide.visible(health?.issues ?? [], skipped: skipped) }
    /// Re-read with the health facts at each refresh, so the banner goes away as soon as access is granted.
    var missingFullDiskAccess: Bool { health?.issues.contains { $0.id == "no_fda" } ?? false }
    /// Sampling produced nothing usable ("Oh-oh" banner).
    var unavailable: Bool { sampled && snapshot.memory.total == 0 && snapshot.disk == nil }

    func start() {
        guard task == nil else { return }
        task = Task {
            var tick = 0
            while !Task.isCancelled {
                if visible || tick % 15 == 0 { await refresh(withProcesses: visible && (tick % 5 == 0 || processes.isEmpty)) }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func due(_ key: String, every interval: TimeInterval) -> Bool {
        if let d = last[key], Date().timeIntervalSince(d) < interval { return false }
        last[key] = Date()
        return true
    }

    /// Re-reads the hungry apps now, e.g. after one was quit.
    func refreshProcesses() async { await refresh(withProcesses: true) }

    /// The Trash is measured once a minute: a file just thrown away, or a Trash just emptied, shows at the next refresh.
    func remeasureTrash() { sampler.remeasureTrash() }

    private func refresh(withProcesses: Bool) async {
        let sampler = self.sampler
        let readDrive = due("drive", every: 3_600)
        let readAccessories = due("accessories", every: visible ? 60 : 300)
        let readMac = mac == nil
        let readXProtect = due("xprotect", every: 3_600)
        let r = await Task.detached {
            (sampler.sample(), withProcesses ? sampler.topProcesses(limit: .max, groupByApp: true) : nil, readDrive ? DriveHealth.read() : nil,
             readAccessories ? PeripheralBattery.read() : nil, ExternalVolume.mounted(), readMac ? MacModel.read() : nil,
             readXProtect ? XProtectStatus.read() : nil)
        }.value
        snapshot = r.0
        history.record(r.0)
        if let p = r.1 {
            processes = Array(p.prefix(5))
            memoryHogs = Array(p.sorted { $0.memory > $1.memory }.prefix(5))
        }
        if let d = r.2 { drive = d }
        if let a = r.3 { accessories = a }
        volumes = r.4
        if let m = r.5 { mac = m }
        if let x = r.6 { xprotect = x }
        sampled = true
        recompute()
        if visible { refreshStorage() }
    }

    func recompute() {
        let alerts = Prefs.alertSettings(capacity: snapshot.disk?.total)
        health = HealthAssessment(snapshot: snapshot, facts: Prefs.guideFacts(drive: drive),
                                  lowDiskBytes: alerts.diskThreshold, trashBytes: alerts.trashThreshold)
    }

    /// Folder sizes are walked rarely, in the background, and only with Full Disk Access (no permission prompt).
    func refreshStorage(force: Bool = false) {
        // The date first: this runs every 2 s with the panel open, the Full Disk Access probe opens files.
        if !force, let s = storage, Date().timeIntervalSince(s.date) < Self.storageInterval { return }
        guard !storageBusy, Permissions.hasFullDiskAccess, let used = snapshot.disk?.used else { return }
        storageBusy = true
        let home = sampler.home
        Task {
            storage = await Task.detached(priority: .background) { StorageBreakdown.compute(home: home, used: used) }.value
            storageBusy = false
        }
    }

    func skip(_ id: String, until: Date) {
        skipped[id] = until
        Prefs.guideSkips = skipped
    }

    func clearSkips() {
        skipped = [:]
        Prefs.guideSkips = [:]
    }
}

/// What a recommendation's button does: open its module, or fix a setting.
enum IssueAction {
    static let titles = Dictionary(uniqueKeysWithValues: Registry.entries.map { ($0.id, $0.title) })

    static func title(_ issue: HealthIssue) -> String? {
        switch issue.id {
        case "no_fda": return "Accorder l'accès"
        case "disabled_menu", "malware_monitor_off": return "Activer"
        default: return issue.module.map { "Ouvrir \(titles[$0] ?? $0)" }
        }
    }

    @MainActor static func perform(_ issue: HealthIssue, monitor: MonitorModel, open: (String) -> Void) {
        switch issue.id {
        case "no_fda": Permissions.openFullDiskAccessSettings()
        case "disabled_menu": UserDefaults.standard.set(true, forKey: MonitorKeys.menuBarEnabled)
        case "malware_monitor_off": UserDefaults.standard.set(true, forKey: MonitorKeys.protectionMonitorEnabled)
        default: if let m = issue.module { open(m) }
        }
        monitor.recompute()
    }
}

/// User-triggered actions shared by the menu, the notifications and the Shortcuts actions.
/// All go through `SafeRemover` / `ActionExecutor` and honour the simulation mode; each returns a line to show.
enum MenuActions {
    static let simulated = "Mode simulation : rien n'a été modifié."

    static func emptyTrash() async -> String {
        let remover = Prefs.context().remover
        return await Task.detached {
            do { return TrashBin.message(try TrashBin.emptyUserTrash(remover: remover), dryRun: remover.dryRun) }
            catch { return TrashBin.unreadable }
        }.value
    }

    static func freeRAM() async -> String {
        let remover = Prefs.context().remover
        return await Task.detached { MemoryPurge.message(MemoryPurge.run(remover: remover), dryRun: remover.dryRun) }.value
    }

    static func runningApp(_ p: ProcessUsage) -> NSRunningApplication? {
        // Grouped lines carry the app bundle path: find the app by it when the pid is one of its helpers.
        let byPath = p.path.flatMap { path in NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path } }
        guard let app = byPath ?? NSRunningApplication(processIdentifier: p.pid),
              QuitPolicy.canQuit(bundleID: app.bundleIdentifier, bundlePath: app.bundleURL?.path,
                                 isRegularApp: app.activationPolicy == .regular, ownBundleID: Bundle.main.bundleIdentifier) else { return nil }
        return app
    }
}


/// The panel under the menu bar icon: health, today's recommendation, a grid of live widgets and quick actions.
struct MenuBarView: View {
    let monitor: MonitorModel
    let openModule: (String) -> Void
    @State private var busy = false
    @State private var ejectError: String?
    /// Result of the last footer action, shown a few seconds.
    @State private var notice: String?
    @Environment(\.openSettings) private var openSettings
    @AppStorage(MonitorKeys.showMenuRecommendations) private var showRecommendations = true
    @AppStorage(MonitorKeys.menuShowExternalDisks) private var showDisks = true

    /// The panel never grows past the screen: beyond that height its content scrolls.
    static var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 16 }

    /// Wide enough to lay widgets out in rows, so the whole panel fits a 13" screen without scrolling.
    static let width: CGFloat = 720

    var body: some View {
        ScrollView(.vertical) { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: Self.width)
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(PanelBackground())
            .handCursorButtons()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if monitor.unavailable {
                Label("Oups, les mesures du Mac sont indisponibles pour le moment.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.m).glass(tint: Theme.warning)
                    .entrance(0)
            }
            if monitor.missingFullDiskAccess {
                FullDiskAccessBanner().entrance(0)
            }
            // The banner above stands for the access recommendation: not listed twice.
            let recommendations = monitor.recommendations.filter { $0.id != "no_fda" }
            HStack(alignment: .top, spacing: DS.Space.s) {
                HealthHeader(health: monitor.health, mac: monitor.mac).entrance(0)
                if showRecommendations, !recommendations.isEmpty {
                    RecommendationsCard(issues: recommendations, monitor: monitor, open: openModule, emptyTrash: emptyTrash, busy: busy).entrance(1)
                }
            }
            .frame(height: RecommendationsCard.height)
            if !monitor.sampled {
                MeasuringPlaceholder().entrance(2)
            } else {
                widgets
            }
            footer.entrance(10)
        }
        .padding(DS.Space.m)
        .frame(width: Self.width)
        .onAppear {
            monitor.visible = true
            monitor.remeasureTrash()
            monitor.start()
            monitor.refreshStorage()
        }
        .onDisappear { monitor.visible = false }
    }

    /// Control Center-like rows: storage and memory, then four small tiles, then devices, disks and hungry apps.
    @ViewBuilder private var widgets: some View {
        let s = monitor.snapshot
        let quit: (ProcessTarget) -> Void = { quitApp($0) }
        row([AnyView(StorageWidget(monitor: monitor, open: openModule, emptyTrash: emptyTrash, busy: busy)),
             AnyView(MemoryWidget(memory: s.memory, history: monitor.history.memory.values, open: openModule, freeRAM: freeRAM, busy: busy,
                                   hogs: monitor.memoryHogs, quit: quit))])
            .entrance(2)
        let small = smallTiles(s, quit: quit)
        row(Array(small.prefix(4))).entrance(3)
        let side = sideTiles(Array(small.dropFirst(4)))
        if monitor.processes.isEmpty {
            if !side.isEmpty { row(side).entrance(4) }
        } else {
            // Devices and disks stacked on the left, the hungry apps list on the right.
            HStack(alignment: .top, spacing: DS.Space.s) {
                if !side.isEmpty {
                    VStack(spacing: DS.Space.s) { ForEach(side.indices, id: \.self) { side[$0] } }
                        .frame(maxWidth: .infinity)
                }
                ProcessesCard(processes: monitor.processes, quit: quit).frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .entrance(4)
        }
        if let ejectError { Text(ejectError).font(.caption2).foregroundStyle(Theme.critical).fixedSize(horizontal: false, vertical: true) }
    }

    /// Small tiles left over from the four-up row, then external disks.
    private func sideTiles(_ rest: [AnyView]) -> [AnyView] {
        var tiles = rest
        if showDisks, !monitor.volumes.isEmpty { tiles.append(AnyView(DisksWidget(volumes: monitor.volumes, eject: ejectVolume))) }
        return tiles
    }

    /// Tiles side by side, all as tall as the tallest.
    private func row(_ tiles: [AnyView]) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            ForEach(tiles.indices, id: \.self) { tiles[$0] }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func smallTiles(_ s: SystemSnapshot, quit: @escaping (ProcessTarget) -> Void) -> [AnyView] {
        var tiles = [AnyView(CPUWidget(snapshot: s, history: monitor.history, processes: monitor.processes, quit: quit))]
        if let b = s.battery { tiles.append(AnyView(BatteryWidget(battery: b, history: monitor.history.battery.values))) }
        tiles.append(AnyView(NetworkWidget(network: s.network, history: monitor.history)))
        tiles.append(AnyView(ProtectionWidget(open: openModule, refreshed: s.date, xprotect: monitor.xprotect)))
        if !monitor.accessories.isEmpty { tiles.append(AnyView(DevicesWidget(devices: monitor.accessories))) }
        return tiles
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            // A toolbar strip as wide as the tiles: quick actions on the left, the way into the app on the right.
            HStack(spacing: DS.Space.s) {
                ConfirmButton(help: MemoryDetail.freeRAMHelp(monitor.snapshot.memory.pressure),
                              confirmHelp: "Cliquez encore pour libérer la mémoire inactive (mot de passe requis).", action: freeRAM) {
                    Label($0 ? "Confirmer" : "Libérer la RAM", systemImage: $0 ? "checkmark" : "memorychip")
                }
                .disabled(busy)
                ConfirmButton(help: monitor.snapshot.trashSize == 0 ? "La corbeille est vide." : "",
                              confirmHelp: "Cliquez encore : les fichiers de la corbeille seront supprimés pour de bon.", action: emptyTrash) {
                    Label($0 ? "Confirmer" : "Vider la corbeille", systemImage: $0 ? "checkmark" : "trash")
                }
                .disabled(busy || monitor.snapshot.trashSize == 0)
                Spacer(minLength: DS.Space.s)
                Menu {
                    Button("Réglages…") { NSApp.activate(); openSettings() }
                    Button("À propos de Vibe Cleaner") { AboutPanel.show() }
                    Divider()
                    Button("Quitter Vibe Cleaner") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.thinMaterial))
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .pointerStyle(.link)
                    .help("Plus d'options").accessibilityLabel("Plus d'options")
                Button { openModule("vibecheck") } label: { Text("Ouvrir Vibe Cleaner").padding(.horizontal, DS.Space.s) }
                    .buttonStyle(GlassButtonStyle(tint: MenuTint.brand, prominent: true))
            }
            .padding(DS.Space.s)
            .glass(radius: DS.Radius.card)
            if busy {
                HStack(spacing: DS.Space.s) { ProgressView().controlSize(.small); Text("En cours…").font(.caption).foregroundStyle(.secondary) }
                    .transition(.opacity)
            } else if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(radius: DS.Radius.control + 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.spring, value: notice)
        .animation(DS.spring, value: busy)
    }

    /// Runs a footer action with a spinner, then shows its result.
    private func act(_ action: @escaping @MainActor () async -> String) {
        busy = true
        notice = nil
        Task {
            let text = await action()
            busy = false
            show(text)
        }
    }

    private func freeRAM() { act { await MenuActions.freeRAM() } }
    private func emptyTrash() {
        act {
            let text = await MenuActions.emptyTrash()
            monitor.remeasureTrash()
            return text
        }
    }
    private func ejectVolume(_ v: ExternalVolume) {
        if Prefs.context().dryRun { show("\(MenuActions.simulated) « \(v.name) » n'a pas été éjecté.") } else { eject(v) }
    }

    /// Asks the app to quit (it handles unsaved documents itself) and refreshes the lists once it is gone.
    private func quitApp(_ target: ProcessTarget) {
        switch target {
        case .app(let app):
            if Prefs.context().dryRun { show("\(MenuActions.simulated) « \(app.localizedName ?? "") » n'a pas été quittée."); return }
            _ = app.terminate()
        case .processes(let name, let targets):
            if Prefs.context().dryRun { show("\(MenuActions.simulated) « \(name) » n'a pas été arrêté."); return }
            let stopped = ProcessStopper.stop(targets)
            show(stopped == targets.count ? "Arrêt demandé : « \(name) »\(targets.count > 1 ? " (\(targets.count) processus)" : "")."
                 : "« \(name) » : \(targets.count - stopped) processus sur \(targets.count) n'ont pas pu être arrêtés (déjà terminés ?).")
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await monitor.refreshProcesses()
        }
    }

    private func show(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(8))
            if notice == text { notice = nil }
        }
    }

    private func eject(_ v: ExternalVolume) {
        ejectError = nil
        let url = v.url
        Task {
            let error = await Task.detached { () -> String? in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: url); return nil } catch { return error.localizedDescription }
            }.value
            if let error { ejectError = "« \(v.name) » n'a pas pu être éjecté. Quittez les apps qui l'utilisent. (\(error))" }
        }
    }
}

/// Before the first reading: zeros would look like real values, so placeholders breathe instead.
struct MeasuringPlaceholder: View {
    var body: some View {
        VStack(spacing: DS.Space.s + 2) {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text("Mesure en cours…").font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .glass()
            HStack(spacing: DS.Space.s + 2) { ghost; ghost }
            HStack(spacing: DS.Space.s + 2) { ghost; ghost }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mesure en cours")
    }

    private var ghost: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)).frame(width: 22, height: 22)
            Capsule().fill(Color.primary.opacity(0.1)).frame(width: 70, height: 14)
            Capsule().fill(Color.primary.opacity(0.06)).frame(height: 6)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }
}

/// Score ring, Mac name and health verdict.
struct HealthHeader: View {
    let health: HealthAssessment?
    var mac: MacModel?

    static func color(_ status: HealthStatus) -> Color {
        switch status {
        case .excellent, .good: Theme.healthy
        case .fair: Color(red: 0.84, green: 1, blue: 0.58)
        case .poor: Theme.warning
        case .critical: Theme.critical
        }
    }

    var body: some View {
        let tint = health.map { Self.color($0.status) } ?? MenuTint.brand
        HStack(spacing: DS.Space.m + 2) {
            MenuRing(value: Double(health?.score ?? 0) / Double(HealthAssessment.maxScore), tint: tint, lineWidth: 7) {
                if let h = health {
                    VStack(spacing: -2) {
                        Text("\(h.score)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("sur 100").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Label(mac.map { [$0.name, $0.chip].compactMap { $0 }.joined(separator: " · ") } ?? "Votre Mac",
                      systemImage: mac?.symbol ?? "laptopcomputer")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text(health.map { "Santé : \($0.status.title)" } ?? "Analyse de votre Mac…").font(.title3.bold())
                Text(health?.status.summary ?? "Les premières mesures arrivent dans un instant.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(tint: tint, radius: DS.Radius.tile)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(health.map { "Santé du Mac : \($0.status.title), score \($0.score) sur 100" } ?? "Mesure en cours")
    }
}

/// Without Full Disk Access the Trash, most caches and Protection are out of reach: said first, with the way to fix it.
struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: DS.Space.m) {
            TileIcon(symbol: "lock.trianglebadge.exclamationmark.fill", tint: Theme.critical, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accès complet au disque requis").font(.callout.weight(.semibold))
                Text("Sans lui, Vibe Cleaner ne peut ni vider la corbeille, ni analyser la plupart des caches et menaces. "
                     + "Activez Vibe Cleaner dans la liste, puis revenez ici.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            Button("Autoriser l'accès") { Permissions.openFullDiskAccessSettings() }
                .buttonStyle(GlassButtonStyle(tint: Theme.critical, prominent: true))
                .help("Ouvre Réglages Système > Confidentialité et sécurité > Accès complet au disque")
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(tint: Theme.critical)
    }
}

/// Every visible recommendation, highest priority first, in a card as tall as the health header: the rest scrolls.
struct RecommendationsCard: View {
    let issues: [HealthIssue]
    let monitor: MonitorModel
    let open: (String) -> Void
    let emptyTrash: () -> Void
    let busy: Bool

    static let height: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text(issues.count > 1 ? "RECOMMANDATIONS" : "RECOMMANDATION DU JOUR")
                    .font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                if issues.count > 1 {
                    Label("\(issues.count)", systemImage: "chevron.down").labelStyle(TrailingIconLabel())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .help("Faites défiler pour voir les \(issues.count) recommandations")
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { i, issue in
                            if i > 0 { Divider() }
                            RecommendationRow(issue: issue, monitor: monitor, open: open, emptyTrash: emptyTrash, busy: busy).id(issue.id)
                        }
                    }
                    .padding(.top, 2)
                }
                // The live panel opened slightly scrolled, cutting the first title: back to the top on each opening.
                .onAppear { proxy.scrollTo(issues[0].id, anchor: .top) }
            }
            .defaultScrollAnchor(.top)
            .scrollIndicators(issues.count > 1 ? .visible : .hidden)
            .scrollBounceBehavior(.basedOnSize)
            // The next recommendation fades out at the bottom edge: a hint that the list goes on.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: issues.count > 1 ? 0.8 : 1),
                                         .init(color: .black.opacity(issues.count > 1 ? 0.15 : 1), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(tint: RecommendationRow.tint(issues[0]))
    }
}

struct RecommendationRow: View {
    let issue: HealthIssue
    let monitor: MonitorModel
    let open: (String) -> Void
    /// The panel's own "Vider la corbeille", for the overfilled Trash recommendation.
    let emptyTrash: () -> Void
    let busy: Bool

    static func tint(_ issue: HealthIssue) -> Color {
        switch issue.severity {
        case .critical: Theme.critical
        case .warning: Theme.warning
        case .info: MenuTint.brand
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.s + 2) {
                TileIcon(symbol: issue.severity >= .warning ? "exclamationmark" : "lightbulb.fill", tint: Self.tint(issue), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title).font(.callout.weight(.semibold))
                        .foregroundStyle(issue.severity >= .warning ? Theme.warningText : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(issue.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Space.s) {
                if issue.id == "trash_bin_overfill" {
                    // Same two-click confirmation as the footer's button.
                    ConfirmButton(tint: MenuTint.brand, prominent: true,
                                  confirmHelp: "Cliquez encore : les fichiers de la corbeille seront supprimés pour de bon.", action: emptyTrash) {
                        Text($0 ? "Confirmer" : "Vider la corbeille")
                    }
                    .disabled(busy)
                } else if let t = IssueAction.title(issue) {
                    Button(t) { IssueAction.perform(issue, monitor: monitor, open: open) }
                        .buttonStyle(GlassButtonStyle(tint: MenuTint.brand, prominent: true))
                }
                SkipMenu(issue: issue, monitor: monitor)
                    .menuStyle(.button).buttonStyle(GlassButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.leading, 38)
        }
        .padding(.trailing, DS.Space.s)
    }
}

/// "Ignorer pour…" on a recommendation, remembered in the preferences.
struct SkipMenu: View {
    let issue: HealthIssue
    let monitor: MonitorModel

    var body: some View {
        Menu("Ignorer") {
            ForEach(SnoozeOption.allCases, id: \.self) { o in
                Button(o.title) { monitor.skip(issue.id, until: o.until(from: Date())) }
            }
        }
        .fixedSize()
    }
}

/// Opaque backdrop of the panel: the menu window's own translucency let the desktop show through.
struct PanelBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(colors: scheme == .dark
                       ? [Color(red: 0.11, green: 0.11, blue: 0.16), Color(red: 0.06, green: 0.06, blue: 0.09)]
                       : [Color(red: 0.97, green: 0.97, blue: 0.98), Color(red: 0.91, green: 0.92, blue: 0.95)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}
