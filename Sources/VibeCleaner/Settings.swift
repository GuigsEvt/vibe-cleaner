import ServiceManagement
import SwiftUI
import VibeCleanerCore

/// User preferences shared by all modules.
enum Prefs {
    static let dryRun = "dryRun"
    static let exclusions = "exclusions"
    static let confirmBeforeCleaning = "confirmBeforeCleaning"
    static let playSound = "playSound"
    /// Newline-separated module ids left out of Vibe Check.
    static let vibeCheckDisabled = "vibeCheckDisabledModules"
    /// Newline-separated `CleanupModule.categories` labels left out of the scan.
    static let junkDisabled = "junkDisabledCategories"
    static let protectionDepth = "protectionDepth"
    static let clutterExternalVolumes = "clutterExternalVolumes"
    static let checkAppUpdates = "checkAppUpdates"
    static let alertLowDisk = "alertLowDisk"
    /// Bytes; 0 = the option closest to 10 % of the boot volume.
    static let alertDiskThreshold = "alertDiskThreshold"
    static let alertTrash = "alertTrash"
    static let alertTrashThreshold = "alertTrashThreshold"
    static let alertLowRAM = "alertLowRAM"
    static let vibeCheckReminder = "vibeCheckReminder"
    static let vibeCheckReminderInterval = "vibeCheckReminderInterval"
    /// Newline-separated bundle ids: the app, its caches, logs and preferences are never touched.
    static let excludedBundleIDs = "excludedBundleIDs"
    /// Newline-separated Team IDs whose signed items Protection leaves alone.
    static let excludedTeamIDs = "excludedTeamIDs"
    static let keepDockIcon = "keepDockIcon"
    /// `MotionPreference` raw value.
    static let reduceMotion = "reduceMotion"
    static let extendedLogs = "extendedLogs"
    static let menuBarEnabled = "menuBarEnabled"
    static let showMenuRecommendations = "showMenuRecommendations"
    static let menuShowExternalDisks = "menuShowExternalDisks"

    static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Mirrors the technical log to `~/Library/Logs/VibeCleaner` while "Journaux détaillés" is on.
    static func applyLogging() {
        let dir = UserDefaults.standard.bool(forKey: extendedLogs) ? LogFile.defaultDirectory : nil
        if Log.file.directory != dir { Log.file.directory = dir }
    }

    static func alertSettings(capacity: Int64?) -> AlertSettings {
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        var s = AlertSettings()
        s.lowDisk = flag(alertLowDisk)
        let disk = Int64(d.integer(forKey: alertDiskThreshold))
        s.diskThreshold = disk > 0 ? disk : AlertSettings.defaultDiskThreshold(capacity: capacity)
        s.trash = flag(alertTrash)
        if d.object(forKey: alertTrashThreshold) != nil { s.trashThreshold = Int64(d.integer(forKey: alertTrashThreshold)) }
        s.lowRAM = flag(alertLowRAM)
        s.reminder = flag(vibeCheckReminder)
        if d.object(forKey: vibeCheckReminderInterval) != nil { s.reminderInterval = d.double(forKey: vibeCheckReminderInterval) }
        return s
    }

    static func context() -> ModuleContext {
        let d = UserDefaults.standard
        return ModuleContext(dryRun: d.bool(forKey: dryRun), exclusions: list(exclusions) + appPaths(list(excludedBundleIDs)))
    }

    static func list(_ key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// An ignored app as paths: its bundles and the per-bundle-id folders of `~/Library`.
    static func appPaths(_ bundleIDs: [String]) -> [String] {
        bundleIDs.flatMap { id in
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path)
                + ["Caches", "Logs", "Containers", "HTTPStorages", "WebKit", "Application Support"].map { "~/Library/\($0)/\(id)" }
                + ["~/Library/Preferences/\(id).plist", "~/Library/Saved Application State/\(id).savedState"]
        }
    }

    /// Sure threats left by the latest Protection scan, for the `malware_detected` factor.
    static let threatIDs = "threatIDs"
    /// Heuristic findings (to check) of the latest Protection scan or of the monitor, for `items_to_review`.
    static let reviewIDs = "reviewIDs"
    /// Unused apps found by the latest Applications scan, for the `unused_apps` factor.
    static let unusedAppCount = "unusedAppCount"

    static var healthFacts: HealthAssessment.Facts {
        let d = UserDefaults.standard
        var f = HealthAssessment.Facts(hasFullDiskAccess: Permissions.hasFullDiskAccess, threats: d.stringArray(forKey: threatIDs)?.count ?? 0,
                                       unusedApps: d.integer(forKey: unusedAppCount))
        f.toReview = Set(d.stringArray(forKey: reviewIDs) ?? []).subtracting(RiskAcceptance.stored).count
        return f
    }

    /// Keeps the score's scan-based facts current after a scan, or after an execution (`processed`).
    static func record(_ results: [ModuleResults], processed: Set<String>? = nil) {
        let d = UserDefaults.standard
        if let processed {
            for key in [threatIDs, reviewIDs] { d.set((d.stringArray(forKey: key) ?? []).filter { !processed.contains($0) }, forKey: key) }
            return
        }
        for r in results {
            switch r.module.id {
            case "protection":
                func ids(_ groups: Set<String>) -> [String] { r.groups.filter { groups.contains($0.id) }.flatMap(\.allItems).map(\.id) }
                d.set(ids(ProtectionModule.confirmedGroupIDs), forKey: threatIDs)
                d.set(ids(ProtectionModule.reviewGroupIDs), forKey: reviewIDs)
            case "applications":
                d.set(r.groups.first { $0.id == "applications.unused" }?.groups.count ?? 0, forKey: unusedAppCount)
            default: break
            }
        }
    }

    static func lines(_ key: String) -> Set<String> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(whereSeparator: \.isNewline).map(String.init))
    }

    /// The modules an entry scans with the current settings applied.
    static func modules(for entry: ModuleEntry) -> [any ScanModule] {
        let skipped = entry.id == "vibecheck" ? lines(vibeCheckDisabled) : []
        return entry.modules.filter { !skipped.contains($0.id) }.map { module in
            switch module {
            case var m as CleanupModule:
                m.disabledCategories = lines(junkDisabled)
                return m
            case var m as ProtectionModule:
                configureProtection(&m, customScan: entry.id == "protection")
                return m
            case var m as ApplicationsModule:
                m.fullDiskAccess = Permissions.hasFullDiskAccess
                m.checkUpdates = UserDefaults.standard.object(forKey: checkAppUpdates) as? Bool ?? true
                return m
            case var m as ClutterModule:
                if UserDefaults.standard.bool(forKey: clutterExternalVolumes) { m.options.externalVolumes = ClutterModule.mountedExternalVolumes() }
                return m
            default:
                return module
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.dryRun) private var dryRun = false
    @AppStorage(Prefs.confirmBeforeCleaning) private var confirm = true
    @AppStorage(Prefs.playSound) private var playSound = true
    @AppStorage(Prefs.keepDockIcon) private var keepDock = true
    @AppStorage(Prefs.reduceMotion) private var motion = MotionPreference.system.rawValue
    @AppStorage(Prefs.extendedLogs) private var extendedLogs = false

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Mode simulation (n'efface rien, affiche ce qui serait fait)", isOn: $dryRun)
                    Toggle("Demander confirmation avant chaque nettoyage", isOn: $confirm)
                    Toggle("Jouer un son en fin d'analyse", isOn: $playSound)
                } header: {
                    SettingsHeader("Nettoyage", symbol: "trash")
                }
                Section {
                    Toggle("Garder l'icône dans le Dock quand la fenêtre est fermée", isOn: $keepDock)
                    Picker("Réduire les animations", selection: $motion) {
                        Text("Comme le système").tag(MotionPreference.system.rawValue)
                        Text("Activé").tag(MotionPreference.enabled.rawValue)
                        Text("Désactivé").tag(MotionPreference.disabled.rawValue)
                    }
                } header: {
                    SettingsHeader("Apparence", symbol: "macwindow")
                } footer: {
                    Text("Sans icône dans le Dock, Vibe Cleaner reste disponible dans la barre des menus.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Journaux détaillés", isOn: $extendedLogs)
                } header: {
                    SettingsHeader("Diagnostic", symbol: "stethoscope")
                } footer: {
                    Text("Écrit un journal technique dans ~/Library/Logs/VibeCleaner, utile pour signaler un problème.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Général", systemImage: "gearshape") }

            ScanSettingsView()
                .tabItem { Label("Analyse", systemImage: "magnifyingglass") }

            Form { ProtectionSettingsSection() }
                .formStyle(.grouped)
                .tabItem { Label("Protection", systemImage: "hand.raised") }

            ExclusionSettingsView()
                .tabItem { Label("Exclusions", systemImage: "eye.slash") }

            MenuSettingsView()
                .tabItem { Label("Menu", systemImage: "menubar.rectangle") }

            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }

            QuarantineView()
                .tabItem { Label("Quarantaine", systemImage: "archivebox") }

            PermissionsTab()
                .tabItem { Label("Autorisations", systemImage: "lock.shield") }
        }
        .padding()
        .frame(width: 680, height: 520)
    }
}

/// Ignore list in three sections, kept as newline-separated defaults (`exclusions` predates the others).
struct ExclusionSettingsView: View {
    @AppStorage(Prefs.exclusions) private var paths = ""
    @AppStorage(Prefs.excludedBundleIDs) private var bundleIDs = ""
    @AppStorage(Prefs.excludedTeamIDs) private var teamIDs = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            Label("Les changements prennent effet à la prochaine analyse.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
            Section {
                editor($paths)
                Button("Ajouter des fichiers ou dossiers…") {
                    add(pick(apps: false).map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }, to: $paths)
                }
            } header: {
                SettingsHeader("Fichiers et dossiers", symbol: "folder")
            } footer: {
                hint("Un chemin par ligne (~ accepté). Rien sous ces chemins n'est jamais supprimé.")
            }
            Section {
                editor($bundleIDs)
                Button("Ajouter des apps…") { add(pick(apps: true).compactMap { Bundle(url: $0)?.bundleIdentifier }, to: $bundleIDs) }
            } header: {
                SettingsHeader("Applications", symbol: "square.grid.2x2")
            } footer: {
                hint("Un identifiant de bundle par ligne. L'app, ses caches, ses journaux et ses préférences ne sont pas touchés.")
            }
            Section {
                editor($teamIDs)
                Button("Ajouter le développeur d'une app…") { add(pick(apps: true).compactMap(Self.teamID), to: $teamIDs) }
            } header: {
                SettingsHeader("Développeurs (Team ID)", symbol: "person.badge.shield.checkmark")
            } footer: {
                hint("Un Team ID par ligne. La Protection ne signale pas les éléments signés par ces développeurs.")
            }
            Section {
                Button("Tout réinitialiser…", role: .destructive) { confirmReset = true }
                    .disabled(paths.isEmpty && bundleIDs.isEmpty && teamIDs.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Vider les trois listes d'exclusion ?", isPresented: $confirmReset) {
            Button("Réinitialiser", role: .destructive) { paths = ""; bundleIDs = ""; teamIDs = "" }
        } message: {
            Text("Les éléments exclus pourront de nouveau apparaître dans les résultats.")
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text).font(.system(.body, design: .monospaced)).frame(minHeight: 64)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Vide. Ajoutez des éléments ici, avec le bouton ci-dessous ou depuis les résultats détaillés (clic droit › Ajouter à la liste d'exclusion).")
                        .font(.callout).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
            }
    }

    private func hint(_ s: String) -> some View { Text(s).font(.caption).foregroundStyle(.secondary) }

    private func pick(apps: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = !apps
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if apps {
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func add(_ values: [String], to text: Binding<String>) {
        var lines = text.wrappedValue.split(whereSeparator: \.isNewline).map(String.init)
        for v in values where !lines.contains(v) { lines.append(v) }
        text.wrappedValue = lines.joined(separator: "\n")
    }

    /// Team ID from the app's static signature (read only, no validity check).
    static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Menu bar and login item. Registering happens only on the user's click, never at launch.
struct MenuSettingsView: View {
    @AppStorage(Prefs.menuBarEnabled) private var enabled = true
    @AppStorage(Prefs.showMenuRecommendations) private var recommendations = true
    @AppStorage(Prefs.menuShowExternalDisks) private var externalDisks = true
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Afficher Vibe Cleaner dans la barre des menus", isOn: $enabled)
                Toggle("Afficher les recommandations", isOn: $recommendations).disabled(!enabled)
                Toggle("Afficher les disques externes", isOn: $externalDisks).disabled(!enabled)
            } header: {
                SettingsHeader("Barre des menus", symbol: "menubar.rectangle")
            }
            Section {
                Toggle("Ouvrir à la connexion", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: setLogin))
                if status == .requiresApproval {
                    HStack {
                        Text("Autorisez Vibe Cleaner dans Réglages Système, Éléments de connexion.").foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir les Réglages") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            } header: {
                SettingsHeader("Connexion", symbol: "person.crop.circle")
            } footer: {
                Text("À l'ouverture de session, Vibe Cleaner démarre sans fenêtre : barre des menus et alertes seulement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Impossible de modifier l'ouverture à la connexion : \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

struct ScanSettingsView: View {
    @AppStorage(Prefs.vibeCheckDisabled) private var vibeCheckDisabled = ""
    @AppStorage(Prefs.clutterExternalVolumes) private var clutterExternalVolumes = false
    @AppStorage(Prefs.checkAppUpdates) private var checkAppUpdates = true
    @AppStorage(Prefs.junkDisabled) private var junkDisabled = ""
    @AppStorage(Prefs.protectionDepth) private var depth = ProtectionModule.ScanDepth.balanced.rawValue

    var body: some View {
        Form {
            Section {
                ForEach(Catalog.vibeCheck, id: \.id) { m in
                    Toggle(m.title, isOn: included(m.id, in: $vibeCheckDisabled))
                }
            } header: {
                SettingsHeader("Modules analysés par Vibe Check", symbol: "laptopcomputer")
            }
            Section {
                ForEach(CleanupModule.categories, id: \.self) { c in
                    Toggle(c, isOn: included(c, in: $junkDisabled))
                }
            } header: {
                SettingsHeader("Catégories analysées par le Nettoyage", symbol: "trash")
            }
            Section {
                Toggle("Rechercher les mises à jour des apps", isOn: $checkAppUpdates)
                Text("Demande à l'App Store et aux serveurs de mise à jour des éditeurs (Sparkle) la dernière version de vos apps. Rien n'est installé.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                SettingsHeader("Applications", symbol: "square.grid.2x2")
            }
            Section {
                Toggle("Inclure les disques externes", isOn: $clutterExternalVolumes)
                Text("macOS peut demander l'autorisation d'accéder aux volumes amovibles.").font(.caption).foregroundStyle(.secondary)
            } header: {
                SettingsHeader("Fouillis", symbol: "square.stack.3d.up")
            }
            Section {
                Picker("Mode d'analyse", selection: $depth) {
                    Text("Rapide").tag(ProtectionModule.ScanDepth.quick.rawValue)
                    Text("Équilibré (recommandé)").tag(ProtectionModule.ScanDepth.balanced.rawValue)
                    Text("Approfondi : ajoute Bureau, Documents et Bibliothèque, plus lent").tag(ProtectionModule.ScanDepth.deep.rawValue)
                }
            } header: {
                SettingsHeader("Protection", symbol: "hand.raised")
            }
            Text("Les changements prennent effet à la prochaine analyse.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    /// A toggle that is on when `value` is absent from the newline-separated `list`.
    private func included(_ value: String, in list: Binding<String>) -> Binding<Bool> {
        Binding {
            !list.wrappedValue.split(whereSeparator: \.isNewline).contains { $0 == value }
        } set: { on in
            var set = list.wrappedValue.split(whereSeparator: \.isNewline).map(String.init).filter { $0 != value }
            if !on { set.append(value) }
            list.wrappedValue = set.joined(separator: "\n")
        }
    }
}

struct NotificationSettingsView: View {
    @AppStorage(Prefs.vibeCheckReminder) private var reminder = true
    @AppStorage(Prefs.vibeCheckReminderInterval) private var interval = AlertSettings().reminderInterval
    @AppStorage(Prefs.alertLowDisk) private var lowDisk = true
    @AppStorage(Prefs.alertDiskThreshold) private var diskThreshold = 0
    @AppStorage(Prefs.alertTrash) private var trash = true
    @AppStorage(Prefs.alertTrashThreshold) private var trashThreshold = Int(AlertSettings().trashThreshold)
    @AppStorage(Prefs.alertLowRAM) private var lowRAM = true
    @State private var resetDone = false

    var body: some View {
        Form {
            Section {
                Toggle("Me rappeler de lancer Vibe Check", isOn: $reminder)
                Picker("Fréquence", selection: $interval) {
                    ForEach(AlertSettings.reminderIntervals, id: \.1) { Text($0.0).tag($0.1) }
                }.disabled(!reminder)
            } header: {
                SettingsHeader("Général", symbol: "bell.badge")
            }
            Section {
                Toggle("Prévenir quand l'espace libre passe sous", isOn: $lowDisk)
                Picker("Seuil", selection: $diskThreshold) {
                    Text("Automatique (environ 10 % du disque)").tag(0)
                    ForEach(AlertSettings.diskThresholds, id: \.self) { Text(FileSizer.format($0)).tag(Int($0)) }
                }.disabled(!lowDisk)
                Toggle("Prévenir quand la corbeille dépasse", isOn: $trash)
                Picker("Seuil", selection: $trashThreshold) {
                    ForEach(AlertSettings.trashThresholds, id: \.self) { Text(FileSizer.format($0)).tag(Int($0)) }
                }.disabled(!trash)
            } header: {
                SettingsHeader("Espace disque", symbol: "internaldrive")
            }
            Section {
                Toggle("Prévenir quand la mémoire libre est trop basse", isOn: $lowRAM)
            } header: {
                SettingsHeader("Mémoire", symbol: "memorychip")
            }
            Section {
                HStack {
                    Button("Réinitialiser les alertes ignorées") {
                        AlertStore.update { $0.snoozedUntil = [:] }
                        resetDone = true
                        Task { try? await Task.sleep(for: .seconds(2)); resetDone = false }
                    }
                    if resetDone { Text("Fait").foregroundStyle(.secondary) }
                }
                Text("Les alertes partent quand Vibe Cleaner est ouvert, au plus une par type et par heure.").font(.caption).foregroundStyle(.secondary)
            }
            NotificationExtraSection()
        }
        .formStyle(.grouped)
    }
}

/// Threats moved aside by Protection, restorable to their original location.
struct QuarantineView: View {
    @State private var entries: [Quarantine.Entry] = []
    @State private var error: String?
    @State private var toPurge: Quarantine.Entry?
    @State private var toRestore: Quarantine.Entry?
    private let quarantine = Quarantine()

    var body: some View {
        VStack(alignment: .leading) {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("La quarantaine est vide.", systemImage: "checkmark.shield")
                } description: {
                    Text("Les menaces isolées par la Protection apparaîtront ici, restaurables à leur emplacement d'origine.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: e.originalPath).lastPathComponent).bold()
                            Text(e.originalPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text("\(e.reason) — \(FileSizer.date(e.date))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restaurer…") { toRestore = e }
                        Button("Supprimer…", role: .destructive) { toPurge = e }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Supprimer définitivement cet élément de la quarantaine ?",
                            isPresented: Binding(get: { toPurge != nil }, set: { if !$0 { toPurge = nil } }), titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                if let e = toPurge { let q = quarantine, remover = Prefs.context().remover; run { try q.purge(e.id, remover: remover) } }
            }
        } message: {
            Text("L'élément sera effacé du disque, sans passer par la Corbeille.")
        }
        // A quarantined item was flagged as a threat: putting it back is never one click.
        .confirmationDialog("Restaurer « \(toRestore.map { URL(fileURLWithPath: $0.originalPath).lastPathComponent } ?? "") » ?",
                            isPresented: Binding(get: { toRestore != nil }, set: { if !$0 { toRestore = nil } }), titleVisibility: .visible) {
            Button("Restaurer") {
                if let e = toRestore { let q = quarantine, remover = Prefs.context().remover; run { try q.restore(e.id, remover: remover) } }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cet élément a été signalé comme menace (\(toRestore?.reason ?? "")). Ne le restaurez que si vous êtes sûr qu'il est sain : il retrouvera son emplacement d'origine.")
        }
    }

    private func reload() { entries = quarantine.list() }

    /// Simulation mode covers the quarantine too: nothing is restored or erased. Runs off the main thread: a root
    /// item waits for the administrator password, and moving a large item takes time.
    private func run(_ action: @escaping @Sendable () throws -> Void) {
        guard !UserDefaults.standard.bool(forKey: Prefs.dryRun) else { error = "Mode simulation : rien n'a été modifié."; return }
        Task {
            let failure = await Task.detached { () -> String? in
                do { try action(); return nil } catch { return error.localizedDescription }
            }.value
            error = failure
            reload()
        }
    }
}

/// Settings › Autorisations, refreshed when the user comes back from System Settings.
struct PermissionsTab: View {
    @State private var fda = Permissions.hasFullDiskAccess

    var body: some View {
        Form {
            Section {
                LabeledContent("Accès complet au disque") {
                    Label(fda ? "Accordé" : "Non accordé", systemImage: fda ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(fda ? .green : .orange)
                }
                Button("Ouvrir les réglages de confidentialité") { Permissions.openFullDiskAccessSettings() }
            } footer: {
                Text("Sans cet accès, Mail, Safari, la Corbeille et les données d'autres apps restent hors de portée de l'analyse.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { fda = Permissions.hasFullDiskAccess }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fda = Permissions.hasFullDiskAccess
        }
    }
}

enum Permissions {
    /// FDA can't be queried directly; reading a TCC-protected file is the standard probe.
    /// The user TCC.db is missing on some systems, so Safari's folder, which always exists, is listed too.
    static var hasFullDiskAccess: Bool { FullDiskAccess.isGranted }

    /// The menu bar panel floats above every normal window and would hide System Settings: it drops to the normal
    /// level, so Settings comes in front while the panel stays open, and floats again when Vibe Cleaner is back in front.
    @MainActor static func openFullDiskAccessSettings() {
        let floating = NSApp.windows.filter { $0.isVisible && $0.level > .normal }.map { ($0, $0.level) }
        floating.forEach { $0.0.level = .normal }
        if !floating.isEmpty {
            Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { break }
                floating.forEach { $0.0.level = $0.1 }
            }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Help menu "À propos de l'accès complet au disque".
    @MainActor static func explainFullDiskAccess() {
        let alert = NSAlert()
        alert.messageText = "À propos de l'accès complet au disque"
        alert.informativeText = """
        État actuel : \(hasFullDiskAccess ? "accordé" : "non accordé").

        macOS protège Mail, Safari, Messages, la Corbeille et les données d'autres apps. Sans cet accès, Vibe Cleaner ne voit pas ces dossiers : moins de fichiers inutiles trouvés, une Protection moins complète et pas de nettoyage des traces de navigation. Rien n'est jamais supprimé sans votre accord.

        Pour l'accorder : Réglages Système, Confidentialité et sécurité, Accès complet au disque, puis activez Vibe Cleaner.
        """
        alert.addButton(withTitle: "Ouvrir les Réglages")
        alert.addButton(withTitle: "Fermer")
        if alert.runModal() == .alertFirstButtonReturn { openFullDiskAccessSettings() }
    }
}

/// Section title of the settings forms: a small icon in the app accent, then the name.
struct SettingsHeader: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent("vibecheck")).frame(width: 18)
        }
    }
}
