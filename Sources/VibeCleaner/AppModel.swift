import SwiftUI
import VibeCleanerCore

/// One entry of the sidebar: a single module, or Vibe Check which runs several.
struct ModuleEntry: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let actionTitle: String
    let modules: [any ScanModule]
}

enum RunPhase {
    case intro
    case scanning(Double, String)
    case results
    case executing(String)
    case summary(ExecutionReport)
}

/// Scan results of one underlying module inside a run (Vibe Check has several).
struct ModuleResults {
    let module: any ScanModule
    var groups: [ResultGroup]
}

@MainActor @Observable
final class ModuleRun {
    let entry: ModuleEntry
    @ObservationIgnored weak var app: AppModel?
    var phase: RunPhase = .intro
    var results: [ModuleResults] = []
    var selection: Set<String> = []
    /// Open apps the selection depends on; non-empty shows the "apps à quitter" sheet.
    var pendingQuit: [AppDependency] = []
    private var pendingContext: ModuleContext?
    private var task: Task<Void, Never>?
    /// Scan progress of each underlying module (Vibe Check cards), by module id; reused for the run status.
    var cards: [String: CardState] = [:]
    /// Last execution report of each module, for the per-card status.
    var reports: [String: ExecutionReport] = [:]
    /// Tile opened with "Revoir" (a module id in Vibe Check, a group id elsewhere); nil shows the tiles.
    var reviewing: String?
    /// Limits the next execution to these item ids (a tile's own "Nettoyer"); nil runs the whole selection.
    var scope: Set<String>?
    /// Module whose card set `scope` (Vibe Check): it runs the items it shares with other modules.
    var scopeModule: String?
    /// The verb of a card: "Désinstaller" for the Applications cards that list apps, the module's otherwise.
    func actionTitle(tile: String?) -> String {
        tile.map(ApplicationsModule.uninstallGroupIDs.contains) == true ? "Désinstaller" : entry.actionTitle
    }
    /// The verb of the reviewed card, or of the card being run.
    var actionTitle: String { actionTitle(tile: reviewing ?? (scope == nil ? nil : scopeModule)) }
    /// Another run already scanning when this one was asked to scan.
    var conflict: ModuleRun?
    /// Vibe Check was asked to scan with every module disabled in the settings.
    var allDisabled = false
    /// Last "Ajouter à la liste d'exclusion", undoable while the banner shows ("Put Back").
    var lastIgnore: IgnoreUndo?
    private var ignoreTimer: Task<Void, Never>?
    /// Modules already scanned, kept when the scan is stopped (incomplete results).
    private var finished: [(Int, ModuleResults)] = []
    // Execution progress: items of finished modules, items started in the current one.
    private(set) var execTotal = 0
    private var execBase = 0
    private var execModule: String?
    private var moduleDone = 0
    private var moduleTotal = 0
    private var stopping = false
    /// "Arrêter" asked by the round button or ⌘. ; the screen confirms before calling `stop()`.
    var stopRequested = false
    /// Another run already executing when this one was asked to execute (single-execution lock).
    var executionConflict: ModuleRun?
    /// Names of the items being executed, for the summary (failures are reported by id).
    private(set) var execNames: [String: String] = [:]
    /// Simulation flag of the last execution, so the summary does not follow a later settings change.
    private(set) var lastDryRun = false
    /// Last items processed by the current execution, newest first (execution screen).
    private(set) var recent: [String] = []
    private let log: Log

    enum QuitChoice { case quit, forceQuit, ignore, cancel }
    enum CardState: Equatable { case waiting, scanning(Double), done }

    struct IgnoreUndo {
        let name: String
        let rule: String
        let results: [ModuleResults]
        let selection: Set<String>
    }

    init(entry: ModuleEntry) {
        self.entry = entry
        log = Log(entry.id)
    }

    var isVibeCheck: Bool { entry.id == "vibecheck" }
    var allGroups: [ResultGroup] { results.flatMap(\.groups) }
    /// Each item once: the same item can appear under several groups (all apps / by publisher, duplicates / tiles).
    var allItems: [ResultItem] {
        var seen = Set<String>()
        return allGroups.flatMap(\.allItems).filter { seen.insert($0.id).inserted }
    }
    var selectedItems: [ResultItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { allItems.reduce(0) { $0 + $1.size } }
    var isBusy: Bool {
        switch phase { case .scanning, .executing: true; default: false }
    }
    var isScanning: Bool {
        if case .scanning = phase { true } else { false }
    }
    var isExecuting: Bool {
        if case .executing = phase { true } else { false }
    }
    /// A scan may start from the intro or a summary only, so it never discards results under review.
    var canStartScan: Bool {
        switch phase { case .intro, .summary: true; default: false }
    }
    /// Items of the tile under review (a module in Vibe Check, a group elsewhere); nil on the tiles.
    var reviewedItemIDs: Set<String>? {
        guard let r = reviewing else { return nil }
        let groups = results.first { $0.module.id == r }?.groups ?? allGroups.filter { $0.id == r }
        return Set(groups.flatMap(\.allItems).filter(\.isActionable).map(\.id))
    }
    /// Selection the next execution acts on (whole selection, or one tile's).
    var effectiveSelection: Set<String> { scope.map { selection.intersection($0) } ?? selection }
    /// Items the next execution will process, for the review before cleaning.
    var pendingItems: [ResultItem] { jobs.flatMap(\.1) }
    var copySetsAtRisk: [ResultGroup] { ResultQueries.fullySelectedCopySets(allGroups, selection: effectiveSelection) }
    var execFraction: Double? {
        execTotal > 0 ? min(1, Double(execBase + max(0, moduleDone - 1)) / Double(execTotal)) : nil
    }

    /// The only entry point to start a scan (round button, ⌘R, "Analyser un dossier…", intents):
    /// applies the single-scan lock (conflict alert), the "every Vibe Check module disabled" alert,
    /// and ignores the request while this run is busy or shows results.
    func requestScan() {
        guard canStartScan else { if entry.id == "protection" { _ = ProtectionCustomScan.consume() }; return }
        if isVibeCheck && Prefs.modules(for: entry).isEmpty { allDisabled = true; return }
        if let other = app?.scanning(except: self) { conflict = other; return }
        scan(context: Prefs.context())
    }

    func resolveConflict(_ other: ModuleRun, abort: Bool) {
        conflict = nil
        // A cancelled custom Protection scan must not leak its folders into the next normal scan.
        guard abort else { if entry.id == "protection" { _ = ProtectionCustomScan.consume() }; return }
        other.stop()
        scan(context: Prefs.context())
    }

    func scan(context: ModuleContext) {
        if case .results = phase { rememberSelection() }
        task?.cancel()
        phase = .scanning(0, "Préparation…")
        results = []
        selection = []
        reviewing = nil
        scope = nil
        reports = [:]
        lastIgnore = nil
        finished = []
        let modules = Prefs.modules(for: entry)
        cards = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, CardState.waiting) })
        log.info("Analyse lancée : \(modules.map(\.id).joined(separator: ", "))\(context.dryRun ? " (simulation)" : "")")
        // Vibe Check scans its modules in parallel; progress is the mean of the cards.
        task = Task {
            await withTaskGroup(of: (Int, [ResultGroup]).self) { group in
                for (i, module) in modules.enumerated() {
                    group.addTask {
                        let groups = await module.scan(context: context) { fraction, step in
                            Task { @MainActor in self.progress(module.id, fraction, step) }
                        }
                        return (i, groups)
                    }
                }
                for await (i, groups) in group {
                    guard !Task.isCancelled else { continue }
                    finished.append((i, ModuleResults(module: modules[i], groups: groups.map { $0.pruned() }.filter { !$0.isEmpty })))
                    cards[modules[i].id] = .done
                }
            }
            guard !Task.isCancelled else { return }
            results = finished.sorted { $0.0 < $1.0 }.map(\.1)
            finished = []
            Prefs.record(results)
            for r in results { ScanHistory.record(r.module.id) }
            if results.contains(where: { ($0.module as? ProtectionModule)?.depth == .deep }) { ScanHistory.record(Prefs.deepScanHistoryID) }
            ScanHistory.record(entry.id)
            selection = initialSelection()
            phase = .results
            log.info("Analyse terminée : \(allItems.count) élément(s), \(FileSizer.format(totalSize))")
            if isVibeCheck { AlertStore.update { $0.lastVibeCheck = Date() } }
            if UserDefaults.standard.object(forKey: Prefs.playSound) as? Bool ?? true { NSSound(named: "Glass")?.play() }
            notify("scanDone", title: "Analyse terminée",
                   body: isVibeCheck ? "Vibe Cleaner est prêt à lancer le nettoyage et l'entretien complets de votre Mac."
                                     : "Les résultats de « \(entry.title) » sont prêts.")
        }
    }

    /// Default selection; Vibe Check applies what the user unchecked in previous runs.
    /// Items whose risk was accepted stay listed but never come pre-selected.
    private func initialSelection() -> Set<String> {
        let picked = isVibeCheck ? SelectionMemory.load(key: Prefs.vibeCheckSelection).selection(for: results.map { ($0.module.id, $0.groups) })
                                 : ResultQueries.initialSelection(allGroups)
        return picked.subtracting(RiskAcceptance.shared.ids)
    }

    /// "J'accepte ce risque" on items, or its undo; accepted items leave the selection.
    func acceptRisk(_ ids: [String], _ accepted: Bool) {
        RiskAcceptance.shared.set(ids, accepted: accepted)
        if accepted { selection.subtract(ids) }
        app?.monitor.recompute()
    }

    private func rememberSelection() {
        guard isVibeCheck, !results.isEmpty else { return }
        var memory = SelectionMemory.load(key: Prefs.vibeCheckSelection)
        memory.capture(results.map { ($0.module.id, $0.groups) }, selection: selection, accepted: RiskAcceptance.shared.ids)
        memory.save(key: Prefs.vibeCheckSelection)
    }

    private func progress(_ id: String, _ fraction: Double, _ step: String) {
        guard case .scanning = phase, cards[id] != .done else { return }
        cards[id] = .scanning(fraction)
        let total = cards.values.reduce(0.0) { sum, c in
            switch c { case .waiting: sum; case .scanning(let f): sum + f; case .done: sum + 1 }
        }
        phase = .scanning(total / Double(max(cards.count, 1)), step)
    }

    /// Scanning: keeps the modules already scanned. Executing: cancels the run task, which stops
    /// between items and ends on the summary with the remaining items reported as not processed.
    func stop() {
        switch phase {
        case .scanning:
            log.info("Analyse arrêtée par l'utilisateur")
            task?.cancel()
            task = nil
            results = finished.sorted { $0.0 < $1.0 }.map(\.1)
            finished = []
            selection = initialSelection()
            phase = results.isEmpty ? .intro : .results
        case .executing:
            log.info("Exécution arrêtée par l'utilisateur")
            stopping = true
            task?.cancel()
            phase = .executing("Arrêt en cours…")
        default:
            break
        }
    }

    /// Each selected item once, run by a single module (`ResultQueries.assignJobs`).
    var jobs: [(any ScanModule, [ResultItem])] {
        let assigned = ResultQueries.assignJobs(results.map { ($0.module.id, $0.groups.flatMap(\.allItems)) },
                                                selection: effectiveSelection, preferred: scope == nil ? nil : scopeModule)
        return zip(results, assigned).map { ($0.module, $1) }
    }

    /// Single-execution lock: another view executing would race on the same items (results are
    /// shared between views). Sets `executionConflict` for the alert and returns false.
    func checkExecutionLock() -> Bool {
        guard let other = app?.executing(except: self) else { return true }
        executionConflict = other
        return false
    }

    /// Asks to quit the apps the selection depends on first, then runs.
    func execute(context: ModuleContext) {
        guard checkExecutionLock() else { scope = nil; return }
        rememberSelection()
        let open = Set(jobs.flatMap { m, items in items.compactMap(m.appDependency(of:)) }).filter(\.isRunning)
        guard open.isEmpty || context.dryRun else {
            pendingQuit = open.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            pendingContext = context
            return
        }
        run(context: context, blocked: [])
    }

    func resolveQuit(_ choice: QuitChoice) {
        guard !pendingQuit.isEmpty, let context = pendingContext else { return }
        guard choice == .cancel || checkExecutionLock() else { pendingQuit = []; pendingContext = nil; scope = nil; return }
        let apps = pendingQuit
        pendingQuit = []
        pendingContext = nil
        guard choice != .cancel else { scope = nil; return }
        stopping = false
        phase = .executing("Fermeture des apps…")
        task = Task {
            if choice != .ignore {
                // Unstructured so that Stop does not turn the quit's wait loop into a busy loop.
                for app in apps where !Task.isCancelled { _ = await Task { await app.quit(force: choice == .forceQuit) }.value }
            }
            guard !Task.isCancelled else { scope = nil; phase = .results; return }
            run(context: context, blocked: Set(apps.filter(\.isRunning)))
        }
    }

    /// Items depending on an app in `blocked` are skipped and reported.
    private func run(context: ModuleContext, blocked: Set<AppDependency>) {
        let jobs = self.jobs.filter { !$0.1.isEmpty }
        reports = [:]
        stopping = false
        // An undo snapshot taken before this run would bring back items it is about to clean.
        lastIgnore = nil
        ignoreTimer?.cancel()
        recent = []
        lastDryRun = context.dryRun
        execNames = Dictionary(jobs.flatMap(\.1).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        execTotal = jobs.reduce(0) { $0 + $1.1.count }
        execBase = 0
        execModule = nil
        cards = Dictionary(uniqueKeysWithValues: jobs.map { ($0.0.id, CardState.waiting) })
        phase = .executing("Exécution…")
        log.info("Exécution lancée : \(execTotal) élément(s)\(context.dryRun ? " (simulation)" : "")")
        task = Task {
            let total = await executeModules(jobs, context: context, blocked: blocked)
            finishRun(total, context: context)
        }
    }

    /// Runs each module's items in turn; per-module reports land in `reports`.
    private func executeModules(_ jobs: [(any ScanModule, [ResultItem])], context: ModuleContext,
                                blocked: Set<AppDependency>) async -> ExecutionReport {
        var total = ExecutionReport()
        // One administrator prompt per run: modules hand their root commands to the collector, run once at the end.
        let collector = AdminCollector()
        var given: [(any ScanModule, Set<String>)] = []
        for (module, items) in jobs {
            var runnable: [ResultItem] = []
            for item in items {
                if let app = module.appDependency(of: item), blocked.contains(app) {
                    total.failures.append((item.id, "« \(app.name) » est toujours ouverte : élément ignoré"))
                } else {
                    runnable.append(item)
                }
            }
            if Task.isCancelled {
                total.failures += runnable.map { ($0.id, ExecutionProgress.stoppedReason) }
                runnable = []
            }
            if !runnable.isEmpty {
                if !stopping { phase = .executing(module.title) }
                execModule = module.id
                moduleDone = 0
                moduleTotal = runnable.count
                cards[module.id] = .scanning(0)
                let id = module.id
                let r = await ActionExecutor.$adminCollector.withValue(collector) {
                    await ExecutionProgress.$onItem.withValue({ item in
                        Task { @MainActor in self.advance(id, item) }
                    }) {
                        await module.execute(runnable, context: context)
                    }
                }
                given.append((module, Set(runnable.map(\.id))))
                reports[module.id] = r
                total.processed += r.processed
                total.freedBytes += r.freedBytes
                total.failures += r.failures
                total.log += r.log
            }
            execModule = nil
            moduleDone = 0
            execBase += items.count
            cards[module.id] = .done
        }
        if !collector.isEmpty {
            if !stopping { phase = .executing("Opérations administrateur") }
            let outcome = await collector.flush(dryRun: context.dryRun)
            for (module, ids) in given {
                let part = outcome.report(for: ids)
                reports[module.id]?.merge(part)
                (module as? PerformanceModule)?.recordHistory(part, dryRun: context.dryRun)
            }
            total.merge(outcome.report)
        }
        return total
    }

    private func finishRun(_ total: ExecutionReport, context: ModuleContext) {
        _ = try? CleanupLog(report: total, module: entry.id, dryRun: context.dryRun).save()
        if !context.dryRun {
            let done = Set(total.processed)
            Prefs.record(results, processed: done)
            // Cleaned items leave the tiles here and in the other views (Vibe Check ↔ module).
            removeItems(done)
            app?.propagate(done, from: self)
            if isVibeCheck && total.outcome == .success {
                let d = UserDefaults.standard
                d.set(d.integer(forKey: Prefs.vibeCheckSuccessCount) + 1, forKey: Prefs.vibeCheckSuccessCount)
            }
        }
        scope = nil
        execTotal = 0
        phase = .summary(total)
        let freed = total.freedBytes > 0 ? ", \(FileSizer.format(total.freedBytes)) libérés" : ""
        log.info("Exécution terminée\(context.dryRun ? " (simulation)" : "") : \(total.processed.count) traité(s), \(total.failures.count) échec(s)\(freed)")
        for f in total.failures { log.error("Échec \(f.id) : \(f.reason)") }
        notify("cleanupDone", title: "Nettoyage terminé", body: "\(total.processed.count) élément(s) traité(s)\(freed).")
    }

    private func advance(_ module: String, _ item: ResultItem) {
        guard execModule == module, moduleDone < moduleTotal else { return }
        moduleDone += 1
        recent.insert(item.name, at: 0)
        if recent.count > 6 { recent.removeLast() }
        cards[module] = .scanning(Double(moduleDone - 1) / Double(moduleTotal))
        if !stopping { phase = .executing("\(execBase + moduleDone) sur \(execTotal) — \(item.name)") }
    }

    /// Posts a local notification only when the app is in the background.
    private func notify(_ kind: String, title: String, body: String) {
        guard !NSApp.isActive, let alerts = app?.alerts else { return }
        let module = entry.id
        Task { await alerts.post(kind: kind, title: title, body: body, module: module) }
    }

    /// Drops processed or ignored items from the results; emptied groups disappear.
    func removeItems(_ ids: Set<String>) {
        guard !ids.isEmpty, !results.isEmpty else { return }
        for i in results.indices { results[i].groups = ResultQueries.removing(ids, from: results[i].groups) }
        selection.subtract(ids)
    }

    var hasRemaining: Bool { !allGroups.isEmpty }

    /// "Revoir les éléments restants": back to the results with what was not processed.
    func reviewRemaining() {
        // After an uninstall from an app list, back to that list to pick the next app; elsewhere, back to the cards.
        if let r = reviewing, ApplicationsModule.uninstallGroupIDs.contains(r), allGroups.contains(where: { $0.id == r }) {} else { reviewing = nil }
        phase = .results
    }

    /// Adds the item to the ignore list and hides every result it covers, undoable with `undoIgnore`.
    func ignore(_ item: ResultItem) {
        guard let url = item.url else { return }
        let home = NSHomeDirectory()
        let rule = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        let d = UserDefaults.standard
        let current = d.string(forKey: Prefs.exclusions) ?? ""
        d.set(current.isEmpty ? rule : current + "\n" + rule, forKey: Prefs.exclusions)
        lastIgnore = IgnoreUndo(name: item.name, rule: rule, results: results, selection: selection)
        let context = ModuleContext(exclusions: [rule])
        let covered = allGroups.flatMap(\.allItems).filter { $0.url.map(context.isExcluded) ?? false }.map(\.id)
        removeItems(Set(covered).union([item.id]))
        // Cross references: an ignore hides the item in the other views too.
        for other in app.map({ Array($0.runs.values) }) ?? [] where other !== self {
            other.lastIgnore = nil
            other.removeItems(Set(other.allItems.filter { $0.url.map(context.isExcluded) ?? false }.map { $0.id }))
        }
        ignoreTimer?.cancel()
        ignoreTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.lastIgnore = nil }
        }
    }

    func undoIgnore() {
        guard let undo = lastIgnore else { return }
        let d = UserDefaults.standard
        var lines = (d.string(forKey: Prefs.exclusions) ?? "").components(separatedBy: "\n")
        if let i = lines.lastIndex(of: undo.rule) { lines.remove(at: i) }
        d.set(lines.joined(separator: "\n"), forKey: Prefs.exclusions)
        results = undo.results
        selection = undo.selection
        lastIgnore = nil
        ignoreTimer?.cancel()
    }

    func reset() {
        if case .results = phase { rememberSelection() }
        task?.cancel()
        phase = .intro
        results = []
        selection = []
        reviewing = nil
        scope = nil
        cards = [:]
        reports = [:]
        lastIgnore = nil
        stopRequested = false
    }

    func toggle(_ item: ResultItem) {
        guard item.isActionable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    /// A group's own box: its actionable items and its bulk subgroups' (`ResultGroup.tickItems`).
    func toggle(_ group: ResultGroup) {
        selection = ResultQueries.toggling(tick: group.tickItems, all: group.allItems, selection: selection)
    }
}

@MainActor @Observable
final class AppModel {
    var entries: [ModuleEntry]
    var runs: [String: ModuleRun] = [:]
    var current: String = "vibecheck"
    /// Direction of the module transition: down the sidebar slides in from the bottom.
    var forward = true
    let radar = RadarModel()
    let monitor = MonitorModel()
    let alerts = AlertCenter()

    init(entries: [ModuleEntry]) {
        self.entries = entries
        for e in entries {
            let run = ModuleRun(entry: e)
            run.app = self
            runs[e.id] = run
        }
        alerts.openModule = { [weak self] id in self?.show(id) }
        alerts.start()
        monitor.start()
        ProtectionMonitorController.shared.start(alerts: alerts)
        IntentBridge.model = self
        VibeCleanerShortcuts.refresh()
    }

    /// Brings the main window forward on a module (menu bar, notifications).
    func show(_ id: String) {
        current = id
        NSApp.activate()
        (AppDelegate.mainWindow ?? NSApp.windows.first { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    /// Sidebar, menu and ⌘1…⌘8 navigation, with the transition direction.
    func select(_ id: String) {
        let order = entries.map(\.id) + ["guide"]
        forward = (order.firstIndex(of: id) ?? 0) >= (order.firstIndex(of: current) ?? 0)
        current = id
    }

    /// Shows a module and asks it to scan through its locks (`ModuleRun.requestScan`).
    /// Returns false when the module is unknown or not on its intro or summary.
    @discardableResult
    func requestScan(_ id: String) -> Bool {
        guard let run = runs[id] else { return false }
        show(id)
        guard run.canStartScan else { return false }
        run.requestScan()
        return true
    }

    /// Single-execution lock: the run executing other than `run`, if any.
    func executing(except run: ModuleRun) -> ModuleRun? {
        runs.values.first { $0 !== run && $0.isExecuting }
    }

    /// Single-scan lock: the run scanning other than `run`, if any.
    func scanning(except run: ModuleRun) -> ModuleRun? {
        runs.values.first { $0 !== run && $0.isScanning }
    }

    /// Cross references: items cleaned in one view leave the others' results.
    func propagate(_ ids: Set<String>, from run: ModuleRun) {
        for other in runs.values where other !== run {
            other.lastIgnore = nil
            other.removeItems(ids)
        }
    }
}
