import SwiftUI
import VibeCleanerCore

struct ModuleScreen: View {
    @Bindable var run: ModuleRun
    @AppStorage(Prefs.confirmBeforeCleaning) private var confirm = true
    @AppStorage(Prefs.dryRun) private var dryRun = false
    @Environment(\.openSettings) private var openSettings
    @State private var reviewSheet = false
    @State private var confirmed = false
    @State private var confirmingReset = false

    var id: String { run.entry.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                switch run.phase {
                case .intro:
                    // The Mac, the text and the round button form one block, centred in the page.
                    centered(in: geo.size) {
                        IntroView(entry: run.entry, heroWidth: Self.heroWidth(geo.size)) {
                            if id == "protection" { ProtectionCustomScanButton(run: run) }
                        }
                    }
                case .scanning(let f, let step):
                    centered(in: geo.size) {
                        VStack(spacing: DS.Space.xl) {
                            ProgressScreen(title: "Analyse en cours", fraction: f, step: step, moduleID: id, symbol: run.entry.symbol)
                            if run.isVibeCheck { ScanCards(run: run).entrance(4) }
                        }
                    }
                case .results:
                    // Vibe Check keeps its cards even when nothing was found ("Rien à signaler" on each).
                    if run.reviewing == nil && !run.isVibeCheck && run.allGroups.isEmpty {
                        // Nothing found: the message and "Terminé" sit together in the middle, like the summary.
                        centered(in: geo.size) {
                            VStack(spacing: DS.Space.m) {
                                GlowSymbol(symbol: "checkmark.seal.fill", tint: Theme.accent(id), size: 100).padding(.bottom, DS.Space.s)
                                Text("Tout est en ordre").font(.title.bold()).entrance(1)
                                Text("Il n'y a rien à nettoyer ou corriger ici.").foregroundStyle(.secondary).entrance(2)
                            }
                        }
                    } else if run.reviewing == nil && (run.isVibeCheck || !run.allGroups.isEmpty) {
                        TilesView(run: run, height: geo.size.height, clean: { ids, tile in startExecute(scope: ids, module: tile) }) { actionButton }
                    } else {
                        // The review list fills the page: its button stays below it.
                        VStack(spacing: 0) {
                            ResultsView(run: run).frame(maxHeight: .infinity)
                            actionButton.padding(.vertical, DS.Space.l)
                        }
                        .frame(maxWidth: .infinity)
                    }
                case .executing(let step):
                    centered(in: geo.size) {
                        VStack(spacing: DS.Space.xl) {
                            ProgressScreen(title: Self.runningTitle(run.actionTitle), fraction: run.execFraction, step: step, moduleID: id,
                                           symbol: run.entry.symbol)
                            Group { if run.isVibeCheck { ScanCards(run: run) } else { RecentItems(names: run.recent, tint: Theme.accent(id)) } }
                                .entrance(4)
                        }
                    }
                case .summary(let report):
                    centered(in: geo.size) {
                        VStack(spacing: DS.Space.l) {
                            SummaryView(report: report, dryRun: run.lastDryRun, moduleID: id, names: run.execNames,
                                        rescan: { run.requestScan() }) {
                                if run.hasRemaining { run.reviewRemaining() } else { run.reset() }
                            }
                            if run.isVibeCheck { CardOutcomes(run: run).entrance(5) }
                        }
                    }
                }
            }
            .modifier(RunDialogs(run: run, reviewSheet: $reviewSheet, confirmed: $confirmed, dryRun: dryRun))
        }
        .sheet(isPresented: Binding(get: { !run.pendingQuit.isEmpty }, set: { if !$0 { run.resolveQuit(.cancel) } })) {
            QuitAppsSheet(apps: run.pendingQuit) { run.resolveQuit($0) }.handCursorButtons()
        }
        .alert("Une tâche est déjà en cours dans « \(run.executionConflict?.entry.title ?? "") ».",
               isPresented: Binding(get: { run.executionConflict != nil }, set: { if !$0 { run.executionConflict = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Attendez la fin de cette tâche avant de lancer celle-ci : les deux pourraient traiter les mêmes éléments.")
        }
        .alert(conflictTitle, isPresented: Binding(get: { run.conflict != nil }, set: { if !$0 { run.conflict = nil } }), presenting: run.conflict) { other in
            Button(other.isVibeCheck ? "Interrompre Vibe Check" : "Interrompre l'analyse en cours", role: .destructive) {
                run.resolveConflict(other, abort: true)
            }
            Button("Annuler", role: .cancel) { run.resolveConflict(other, abort: false) }
        } message: { _ in
            Text("Une seule analyse à la fois. Voulez-vous l'interrompre et continuer avec « \(run.entry.title) » ?")
        }
    }

    private var conflictTitle: String {
        guard let other = run.conflict else { return "" }
        return other.isVibeCheck ? "Une analyse Vibe Check est déjà en cours." : "Une analyse est déjà en cours dans « \(other.entry.title) »."
    }

    /// Whole selection (`scope` nil) or one tile's: reviewed first when the setting asks for it,
    /// and always when every copy of a duplicate set is selected. `module`: the tile (a module in Vibe Check),
    /// which runs the items it shares with other modules.
    private func startExecute(scope: Set<String>?, module: String? = nil) {
        guard run.checkExecutionLock() else { return }
        run.scope = scope
        run.scopeModule = module
        if confirm || !run.copySetsAtRisk.isEmpty { reviewSheet = true } else { run.execute(context: Prefs.context()) }
    }

    /// Title of the execution screen, in correct French for each module's action.
    static func runningTitle(_ action: String) -> String {
        switch action {
        case "Nettoyer": "Nettoyage en cours"
        case "Supprimer": "Suppression en cours"
        case "Désinstaller": "Désinstallation en cours"
        case "Protéger": "Suppression des menaces en cours"
        case "Lancer": "Exécution des tâches en cours"
        case "Libérer": "Libération de l'espace en cours"
        default: "Traitement en cours"
        }
    }

    private var header: some View {
        HStack {
            // Reviewing a card: the way back to the cards, top left. On the cards: a new analysis, discreet, top right.
            if case .results = run.phase, run.reviewing != nil {
                Button { run.reviewing = nil } label: { Label("Terminé", systemImage: "chevron.left") }
                    .buttonStyle(GlassButtonStyle())
                    .help("Revenir aux cartes")
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer()
            if case .results = run.phase, run.reviewing == nil {
                Button { confirmingReset = true } label: { Label("Nouvelle analyse", systemImage: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle())
                    .help("Effacer ces résultats et analyser de nouveau")
            }
            if dryRun {
                Label("Simulation", systemImage: "eye").font(.caption.weight(.semibold)).foregroundStyle(Theme.warningText)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glass(tint: Theme.warning, radius: 12)
                    .help("Mode simulation : rien n'est modifié sur le Mac")
            }
        }
        .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.m).frame(height: 44)
        .confirmationDialog("Effacer ces résultats et lancer une nouvelle analyse ?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Nouvelle analyse", role: .destructive) { run.reset(); run.requestScan() }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Tous les modules de Vibe Check sont désactivés.", isPresented: $run.allDisabled) {
            Button("Ouvrir les réglages") { openSettings() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Activez au moins un module dans Réglages > Analyse pour lancer Vibe Check.")
        }
    }

    /// Content and round button stacked and centred vertically; scrolls when the window is too short.
    private func centered<Content: View>(in size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                content()
                actionButton
            }
            .padding(.vertical, DS.Space.l)
            .frame(width: size.width)
            .frame(minHeight: size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Mac width on the intro: room is kept for the text, the chips and the round button below it.
    static func heroWidth(_ size: CGSize) -> CGFloat {
        min(300, max(150, min(size.width * 0.36, (size.height - 380) / 0.78)))
    }

    @ViewBuilder private var actionButton: some View {
            Group {
            switch run.phase {
            case .intro:
                ActionButton(title: "Analyser", moduleID: id) { run.requestScan() }
            case .scanning, .executing:
                ActionButton(title: "Arrêter", moduleID: id) { run.stopRequested = true }
            case .results:
                if run.allGroups.isEmpty {
                    ActionButton(title: "Terminé", moduleID: id) { run.reset() }
                } else if run.reviewedItemIDs?.isEmpty == true {
                    // A tile to read only (updates, links): nothing to run, so no action button.
                    EmptyView()
                } else {
                    // Under review, the button acts on the reviewed tile only, as its counter shows; the cards run everything.
                    let reviewed = run.reviewedItemIDs
                    ActionButton(title: run.actionTitle, moduleID: id,
                                 enabled: !(reviewed.map { run.selection.intersection($0) } ?? run.selection).isEmpty,
                                 disabledHint: selectFirstHint(run.actionTitle)) { startExecute(scope: reviewed, module: run.reviewing) }
                }
            case .summary:
                EmptyView()
            }
            }
            .entrance(3)
    }
}

/// Stop confirmation and the review sheet, shared by every phase of a module screen.
private struct RunDialogs: ViewModifier {
    @Bindable var run: ModuleRun
    @Binding var reviewSheet: Bool
    @Binding var confirmed: Bool
    let dryRun: Bool

    func body(content: Content) -> some View {
        content
        .confirmationDialog(run.isScanning ? "Voulez-vous arrêter l'analyse avant la fin ?" : "Voulez-vous arrêter toutes les tâches en cours ?",
                            isPresented: $run.stopRequested, titleVisibility: .visible) {
            Button("Arrêter", role: .destructive) { run.stop() }
            Button(run.isScanning ? "Continuer l'analyse" : "Continuer", role: .cancel) {}
        } message: {
            Text(run.isScanning ? "Interrompre l'analyse laissera des résultats incomplets."
                                : "L'élément en cours se termine ; les suivants ne seront pas traités.")
        }
        .sheet(isPresented: $reviewSheet, onDismiss: {
            // Executing after the sheet is gone lets the "apps à quitter" sheet show.
            if confirmed { confirmed = false; run.execute(context: Prefs.context()) } else { run.scope = nil }
        }) {
            ReviewSheet(run: run, dryRun: dryRun) { ok in
                confirmed = ok
                reviewSheet = false
            }.handCursorButtons()
        }
    }
}

/// Review before cleaning: what will be processed, which operations ask for
/// the administrator password, and the "every copy selected" warning of Fouillis.
struct ReviewSheet: View {
    let run: ModuleRun
    let dryRun: Bool
    let done: (Bool) -> Void

    static let shown = 300

    var body: some View {
        let jobs = run.jobs
        let items = jobs.flatMap(\.1)
        let admin = ResultQueries.adminItems(items)
        let atRisk = run.copySetsAtRisk
        let tint = Theme.accent(run.entry.id)
        // Applications and Protection run their own root batch (ordering and manifests); the others share one.
        let owners = jobs.filter { !ResultQueries.adminItems($0.1).isEmpty }.map(\.0.id)
        let separate = owners.filter { ["applications", "protection"].contains($0) }.count
        let prompts = separate + (owners.count > separate ? 1 : 0)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SheetHeader(symbol: run.entry.symbol, tint: tint,
                        title: ResultQueries.reviewTitle(items, action: run.actionTitle),
                        message: dryRun ? "Mode simulation : rien ne sera modifié."
                                        : "Les éléments marqués « Définitif » ou « Irréversible » ne pourront pas être récupérés ; les autres vont à la Corbeille ou en quarantaine.")
            if let note = ResultQueries.reviewNote(items) {
                Label(note, systemImage: note.contains("Wi-Fi") ? "wifi.slash" : "square.grid.2x2").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !atRisk.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Label("Toutes les copies sont sélectionnées", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(Theme.warningText)
                    Text("Pour \(atRisk.count == 1 ? "ce fichier" : "ces \(atRisk.count) fichiers"), aucun exemplaire ne sera conservé : \(atRisk.prefix(5).map(\.title).joined(separator: ", "))\(atRisk.count > 5 ? "…" : "").")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                .glass(tint: Theme.warning, radius: DS.Radius.control + 2)
            }
            if !admin.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Label(prompts > 1 ? "Mot de passe administrateur demandé \(prompts) fois (Applications et Protection ont leur propre demande) pour :"
                                      : "Mot de passe administrateur demandé une seule fois pour :", systemImage: "lock.fill").font(.callout.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(admin.prefix(8)) { Text("• \($0.name)").font(.caption).lineLimit(1).truncationMode(.middle) }
                    if admin.count > 8 { Text("et \(admin.count - 8) autre(s)").font(.caption).foregroundStyle(.secondary) }
                    Text(admin.contains(where: \.isIrreversible) ? "Certaines de ces opérations ne pourront pas être annulées."
                         : "Les éléments système sont mis de côté dans /Library/Application Support/VibeCleaner/Corbeille (vidable depuis Nettoyage › Corbeilles).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                .glass(tint: tint, radius: DS.Radius.control + 2)
            }
            List {
                ForEach(jobs, id: \.0.id) { module, picked in
                    if !picked.isEmpty {
                        Section(run.isVibeCheck ? "\(module.title) (\(picked.count))" : "\(picked.count) élément(s)") {
                            ForEach(picked.prefix(Self.shown)) { item in
                                HStack(spacing: DS.Space.s) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).lineLimit(1).truncationMode(.middle)
                                        if let d = item.url?.path ?? item.detail {
                                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    Spacer()
                                    if item.isIrreversible {
                                        Text(Self.isPermanent(item) ? "Définitif" : "Irréversible").font(.caption2.bold()).foregroundStyle(Theme.warningText)
                                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.warning.opacity(0.15), in: Capsule())
                                    }
                                    if item.size > 0 { Text(FileSizer.format(item.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                                .listRowBackground(Color.clear)
                            }
                            if picked.count > Self.shown { Text("et \(picked.count - Self.shown) autre(s)…").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 180, maxHeight: 320)
            .glass(tint: tint, radius: DS.Radius.card)
            HStack(spacing: DS.Space.s) {
                Button("Annuler", role: .cancel) { done(false) }.keyboardShortcut(.cancelAction).buttonStyle(GlassButtonStyle())
                Spacer()
                if atRisk.isEmpty {
                    Button(run.actionTitle) { done(true) }.keyboardShortcut(.defaultAction).disabled(items.isEmpty)
                        .buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
                } else {
                    // Every copy selected: no default action, ↩ must not delete the last copy.
                    Button("Supprimer toutes les copies", role: .destructive) { done(true) }.disabled(items.isEmpty)
                        .buttonStyle(GlassButtonStyle(tint: Theme.critical, prominent: true))
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 580)
        .background(SheetBackground(tint: tint))
    }

    static func isPermanent(_ item: ResultItem) -> Bool {
        if case .delete(_, .permanent, _) = item.action { true } else { false }
    }
}

/// Module intro: the Mac lit with the module colour, title, subtitle and what the module looks at.
struct IntroView<Extra: View>: View {
    let entry: ModuleEntry
    /// Fixed Mac width for hosts that stack other content under the intro (Radar); nil fills the screen.
    var heroWidth: CGFloat? = nil
    @ViewBuilder var extra: () -> Extra

    /// Vibe Check greets a first run, then a returning user.
    private var title: String {
        guard entry.id == "vibecheck" else { return entry.title }
        return ScanHistory.last("vibecheck") == nil ? "Bienvenue dans Vibe Cleaner" : "Bon retour !"
    }
    private var subtitle: String {
        entry.id == "vibecheck" ? "Commencez par une analyse rapide et complète de votre Mac." : entry.subtitle
    }

    var body: some View {
        if let heroWidth {
            content(hero: heroWidth)
        } else {
            GeometryReader { geo in
                // The Mac takes what the text leaves: about 300 pt wide in a large window, 260 at the 980 × 640 minimum.
                content(hero: min(300, max(170, min(geo.size.width * 0.38, (geo.size.height - 250) / 0.78))))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    private func content(hero: CGFloat) -> some View {
        let tint = Theme.accent(entry.id)
        return VStack(spacing: DS.Space.l) {
                // A laptop on the laptop screen would be odd: Vibe Check shows its check mark there.
                MacHero(tint: tint, symbol: entry.id == "vibecheck" ? "checkmark.circle" : entry.symbol, width: hero)
                    .padding(.bottom, DS.Space.s)
                    .entrance(0)
                VStack(spacing: DS.Space.s) {
                    Text(title).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                    Text(subtitle).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                }
                .entrance(1)
                let chips = IntroChips.chips(for: entry)
                if !chips.isEmpty { ChipRow(chips: chips, tint: tint).entrance(2) }
                extra().entrance(3)
            }
            .padding(.horizontal, DS.Space.xl)
    }
}

extension IntroView where Extra == EmptyView {
    /// Compact intro for a host that adds its own content below.
    init(entry: ModuleEntry) { self.init(entry: entry, heroWidth: 140) { EmptyView() } }
}

/// Scan and execution progress: a glowing ring with the accent gradient, the percentage and the current step.
struct ProgressScreen: View {
    let title: String
    let fraction: Double?
    let step: String
    let moduleID: String
    var symbol: String? = nil

    var body: some View {
        let tint = Theme.accent(moduleID)
        VStack(spacing: DS.Space.l) {
            ZStack {
                Circle().fill(RadialGradient(colors: [tint.opacity(0.35), .clear], center: .center, startRadius: 40, endRadius: 140))
                    .frame(width: 280, height: 280)
                Circle().fill(.ultraThinMaterial).frame(width: 136, height: 136)
                Circle().fill(LinearGradient(colors: [tint.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)).frame(width: 136, height: 136)
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).frame(width: 136, height: 136)
                Group {
                    if let fraction {
                        RingGauge(value: fraction, tint: tint, lineWidth: 12) { EmptyView() }
                    } else {
                        ZStack {
                            Circle().stroke(.white.opacity(0.1), lineWidth: 12)
                            IndeterminateRing(tint: tint)
                        }
                    }
                }
                .frame(width: 172, height: 172)
                VStack(spacing: 2) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint) }
                    if let fraction {
                        Text("\(Int(fraction * 100)) %").font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: fraction))
                            .animation(.smooth, value: Int(fraction * 100))
                    }
                }
            }
            .frame(width: 200, height: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(fraction.map { "\(Int($0 * 100)) %" } ?? "En cours")
            .entrance(0)
            Text(title).font(.title2.bold()).entrance(1)
            if !step.isEmpty {
                Label(step, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
                    .glass(tint: tint, radius: 14)
                    .frame(maxWidth: 520)
                    .entrance(2)
            }
        }
    }
}

struct SummaryView: View {
    let report: ExecutionReport
    let dryRun: Bool
    let moduleID: String
    /// Item names by id, so failures read as names rather than internal ids.
    var names: [String: String] = [:]
    /// "Revoir les éléments restants", when some results were not processed.
    let rescan: () -> Void
    /// Back to the remaining results, or to the intro when nothing is left.
    let done: () -> Void
    @State private var showLog = false

    var body: some View {
        let tint = Theme.accent(moduleID)
        VStack(spacing: DS.Space.m) {
            GlowSymbol(symbol: icon, tint: color, size: 104).padding(.bottom, DS.Space.s)
            Text(title).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center).entrance(1)
            VStack(spacing: 2) {
                if report.freedBytes > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text(FileSizer.format(report.freedBytes))
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom))
                        Text(dryRun ? "libérés (simulation)" : "libérés").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("\(report.processed.count) élément(s) traité(s)\(report.freedBytes == 0 && dryRun ? " (simulation)" : "")")
                    .foregroundStyle(.secondary)
            }
            .entrance(2)
            if !report.failures.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Label("Erreurs (\(report.failures.count))", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(Theme.critical)
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, f in
                                Text("\(names[f.id] ?? f.id) — \(f.reason)").font(.caption).textSelection(.enabled)
                                    .help(f.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 96)
                }
                .padding(DS.Space.m)
                .glass(tint: Theme.critical, radius: DS.Radius.card)
                .frame(maxWidth: 600)
                .entrance(3)
            }
            HStack(spacing: DS.Space.s) {
                Button("Analyser à nouveau", action: rescan).buttonStyle(GlassButtonStyle())
                Menu {
                    Button(showLog ? "Masquer le journal" : "Afficher le journal") { showLog.toggle() }
                    Button("Copier le journal") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CleanupLog(report: report, module: moduleID, dryRun: dryRun).text, forType: .string)
                    }
                    Button("Ouvrir le dossier des journaux") { NSWorkspace.shared.open(CleanupLog.defaultRoot) }
                } label: {
                    Label("Journal", systemImage: "doc.text.magnifyingglass")
                }
                .menuStyle(.button)
                .buttonStyle(GlassButtonStyle())
                .fixedSize()
                Button("Terminé", action: done).keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
            }
            .padding(.top, DS.Space.xs)
            .entrance(4)
            if showLog {
                ScrollView {
                    Text(report.log.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 600, maxHeight: 150).padding(DS.Space.s)
                .glass(radius: DS.Radius.control + 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DS.spring, value: showLog)
        .padding()
    }

    var icon: String {
        switch report.outcome { case .success, .empty: "checkmark"; case .partial: "exclamationmark"; case .failure: "xmark" }
    }
    var color: Color {
        switch report.outcome { case .success, .empty: Theme.accent(moduleID); case .partial: Theme.warning; case .failure: Theme.critical }
    }
    var title: String {
        switch report.outcome {
        case .success: moduleID == "vibecheck" ? "Bravo ! Votre Mac est en pleine forme !" : "C'est fait"
        case .empty: "Rien à faire"
        case .partial: "Terminé avec des erreurs"
        case .failure: "Échec"
        }
    }
}

/// "Apps à quitter": the selection needs these apps closed.
struct QuitAppsSheet: View {
    let apps: [AppDependency]
    let choose: (ModuleRun.QuitChoice) -> Void

    var body: some View {
        let tint = Theme.accent("applications")
        VStack(alignment: .leading, spacing: DS.Space.l) {
            SheetHeader(symbol: "xmark.app", tint: tint, title: "Quitter ces applications ?",
                        message: "Certains éléments sélectionnés ne peuvent être traités que si ces apps sont fermées. Les documents non enregistrés peuvent être perdus avec « Forcer à quitter ».")
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element) { i, app in
                    if i > 0 { Divider().opacity(0.4) }
                    HStack(spacing: DS.Space.m) {
                        if let icon = app.runningApplications.first?.icon { Image(nsImage: icon).resizable().frame(width: 30, height: 30) }
                        else { TintedIcon(symbol: "app", tint: tint, size: 30) }
                        Text(app.name).font(.body.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                }
            }
            .glass(tint: tint, radius: DS.Radius.card)
            HStack(spacing: DS.Space.s) {
                Button("Annuler", role: .cancel) { choose(.cancel) }.keyboardShortcut(.cancelAction).buttonStyle(GlassButtonStyle())
                Spacer()
                Button("Ignorer") { choose(.ignore) }.help("Continuer sans quitter : les éléments liés à ces apps seront sautés")
                    .buttonStyle(GlassButtonStyle())
                Button("Forcer à quitter", role: .destructive) { choose(.forceQuit) }.buttonStyle(GlassButtonStyle(tint: Theme.critical))
                Button("Quitter") { choose(.quit) }.keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 500)
        .background(SheetBackground(tint: tint))
    }
}

/// One Vibe Check card while scanning, running or done: tinted icon, title and an animated status.
struct VibeCheckCard<Status: View>: View {
    let moduleID: String
    let symbol: String
    let title: String
    var active = false
    var dimmed = false
    @ViewBuilder var status: () -> Status

    var body: some View {
        let tint = Theme.accent(moduleID)
        VStack(spacing: DS.Space.s) {
            TintedIcon(symbol: symbol, tint: tint, size: 34)
            Text(title).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.85)
            status()
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(minHeight: 30, alignment: .top)
        }
        .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.m)
        .frame(width: 128)
        .glass(tint: tint, radius: DS.Radius.card, selected: active)
        .scaleEffect(active ? 1.03 : 1)
        .opacity(dimmed ? 0.5 : 1)
        .animation(DS.spring, value: active)
        .accessibilityElement(children: .combine)
    }
}

/// Vibe Check cards while scanning or running: waiting, in progress, done, or disabled in the settings.
struct ScanCards: View {
    let run: ModuleRun

    var body: some View {
        let skipped = Prefs.lines(Prefs.vibeCheckDisabled)
        HStack(spacing: DS.Space.m) {
            ForEach(run.entry.modules.filter { run.cards[$0.id] != nil || (run.isScanning && skipped.contains($0.id)) }, id: \.id) { m in
                let state = run.cards[m.id]
                VibeCheckCard(moduleID: m.id, symbol: m.symbol, title: m.title, active: { if case .scanning = state { true } else { false } }(),
                              dimmed: state == nil) {
                    switch state {
                    case .scanning(let f):
                        HStack(spacing: 5) {
                            RingGauge(value: f, tint: Theme.accent(m.id), lineWidth: 2.5) { EmptyView() }.frame(width: 14, height: 14)
                            Text("\(run.isScanning ? "" : "En cours · ")\(Int(f * 100)) %").monospacedDigit()
                        }
                    case .done:
                        if run.isScanning {
                            Image(systemName: "checkmark.circle.fill").font(.body).foregroundStyle(Theme.accent(m.id))
                                .transition(.scale.combined(with: .opacity))
                                .accessibilityLabel("Terminé")
                        } else { Text(CardOutcomes.status(run.reports[m.id])) }
                    case .waiting: Text("En attente…")
                    case nil: Text("Désactivée dans les réglages")
                    }
                }
                .animation(DS.spring, value: state)
            }
        }
    }
}

/// Vibe Check: what each card did.
struct CardOutcomes: View {
    let run: ModuleRun

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ForEach(Array(run.results.enumerated()), id: \.element.module.id) { i, r in
                let report = run.reports[r.module.id]
                // Still ticked after the run: left out by a run limited to another card.
                let ticked = r.groups.contains { $0.allItems.contains { run.selection.contains($0.id) } }
                VibeCheckCard(moduleID: r.module.id, symbol: r.module.symbol, title: r.module.title, dimmed: report == nil && !r.groups.isEmpty) {
                    Text(Self.status(report, hadItems: !r.groups.isEmpty, ticked: ticked))
                }
                .entrance(i)
            }
        }
    }

    /// A card left unchecked reads "Non sélectionnée"; one still checked but out of the run's scope, "Non lancée";
    /// one with nothing found, "Rien à faire".
    static func status(_ r: ExecutionReport?, hadItems: Bool = false, ticked: Bool = false) -> String {
        guard let r else { return hadItems ? (ticked ? "Non lancée" : "Non sélectionnée") : "Rien à faire" }
        let freed = r.freedBytes > 0 ? "\n\(FileSizer.format(r.freedBytes))" : ""
        switch r.outcome {
        case .success: return "Terminé" + freed
        case .partial: return "Terminé avec erreurs" + freed
        case .failure: return "Échec"
        case .empty: return "Rien à faire"
        }
    }
}

/// Execution screen outside Vibe Check: the item in progress and the last ones processed.
struct RecentItems: View {
    let names: [String]
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                HStack(spacing: DS.Space.s) {
                    Image(systemName: i == 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                        .foregroundStyle(i == 0 ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout).foregroundStyle(i == 0 ? .primary : .secondary)
                .opacity(1 - Double(i) * 0.12)
            }
        }
        .padding(names.isEmpty ? 0 : DS.Space.m)
        .frame(width: 440, alignment: .leading)
        .glass(tint: names.isEmpty ? nil : tint, radius: DS.Radius.card)
        .opacity(names.isEmpty ? 0 : 1)
        .animation(DS.spring, value: names)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(names.isEmpty ? "" : "En cours : \(names[0])")
    }
}
