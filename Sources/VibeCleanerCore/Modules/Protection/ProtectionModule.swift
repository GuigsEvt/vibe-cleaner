import AppKit
import Foundation

/// Threat detection without proprietary signatures: persistence, process, extension and code-signature heuristics,
/// Apple's own XProtect YARA rules when the `yara` CLI is installed, and an optional local SHA-256 list.
/// Threats go to a restorable quarantine. Also lists privacy traces: browsers, app permissions (TCC),
/// Recent Items lists and known Wi-Fi networks.
public struct ProtectionModule: ScanModule {
    public enum ScanDepth: String, Sendable, CaseIterable { case quick, balanced, deep }

    public let id = "protection"
    public let title = "Protection"
    public let subtitle = "Recherche les programmes lancés au démarrage suspects, les apps à la signature invalide et les fichiers reconnus par les règles XProtect d'Apple."
    public let symbol = "shield.lefthalf.filled"
    public let actionTitle = "Protéger"
    public var depth: ScanDepth
    public var quarantine: Quarantine
    /// Non-empty: a custom scan of these folders or files only (malware checks, no persistence or privacy).
    public var customRoots: [URL] = []
    /// Code-signing Team IDs the user trusts; their programs are never reported.
    public var excludedTeamIDs: Set<String> = []
    /// Expand PKG installers (DMG images are matched as raw files by YARA, never mounted). Off by default:
    /// expanding writes into the temporary folder during the scan.
    public var scanDiskImages = false
    /// Expand ZIP archives found in Downloads, Mail attachments and custom folders. Off by default, as above.
    public var scanArchives = false
    public var scanMailAttachments = true
    /// External volumes up to `maxExternalVolume`; off by default (reading them without Full Disk Access prompts).
    public var scanExternalDrives = false
    /// False skips the folders whose access would show a macOS permission prompt (Downloads, Desktop, Documents,
    /// other apps' containers, external volumes). False by default; the app and the CLI set `FullDiskAccess.isGranted`.
    public var fullDiskAccess = false
    public var includePrivacy = true

    static let maxExternalVolume: Int64 = 64_000_000_000

    /// Groups that count as threats for the health score and notifications.
    public static let threatGroupIDs: Set<String> = ["prot.persistence", "prot.yara", "prot.hashes", "prot.cron", "prot.processes",
                                                     "prot.extensions", "prot.homepage", "prot.custom"]
    /// Sure detections: an XProtect rule or a known hash matched. They alone count as malware in the score;
    /// the other threat groups are heuristics, items to check (`reviewGroupIDs`).
    public static let confirmedGroupIDs: Set<String> = ["prot.yara", "prot.hashes", "prot.custom"]
    public static var reviewGroupIDs: Set<String> { threatGroupIDs.subtracting(confirmedGroupIDs) }

    public init(depth: ScanDepth = .balanced, quarantine: Quarantine = Quarantine()) {
        self.depth = depth
        self.quarantine = quarantine
    }

    static let xprotectRules = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.yara"
    static let interpreters: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python3", "/usr/bin/perl", "/usr/bin/ruby",
                                            "/usr/bin/osascript", "/usr/bin/env", "/usr/local/bin/node", "/opt/homebrew/bin/node"]
    /// Script runtimes recognised by name wherever they are installed (~/.nvm, ~/.bun, ~/.deno, Homebrew…).
    static let interpreterNames: Set<String> = ["node", "bun", "deno"]

    /// A script interpreter: the interesting file is the script it runs. Never one in /tmp or /Users/Shared.
    static func isInterpreter(_ path: String) -> Bool {
        interpreters.contains(path)
            || (interpreterNames.contains((path as NSString).lastPathComponent) && !isSuspiciousLocation(URL(fileURLWithPath: path), home: URL(fileURLWithPath: "/")))
    }

    public static var yaraPath: String? {
        ["/opt/homebrew/bin/yara", "/usr/local/bin/yara"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var yaraAvailable: String? {
        FileManager.default.isReadableFile(atPath: xprotectRules) ? yaraPath : nil
    }

    func fileScan(context: ModuleContext) -> FileScan {
        FileScan(yara: Self.yaraAvailable, rules: Self.xprotectRules, hashes: HashList(home: context.home),
                 expandPKG: scanDiskImages, expandArchives: scanArchives)
    }

    public func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup] {
        if !customRoots.isEmpty { return scanCustom(context: context, progress: progress) }
        progress(0.05, "Éléments lancés au démarrage")
        var groups = [scanPersistence(context: context), Cron.group(crontab: Shell.run("/usr/bin/crontab", ["-l"]).stdout)]
        if Task.isCancelled { return [] }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/profiles") {
            groups.append(ConfigProfiles.group(output: Shell.run("/usr/bin/profiles", ["list"]).stdout))
        }
        progress(0.2, "Processus en cours")
        groups.append(Processes.group(Processes.all(), context: context, excludedTeamIDs: excludedTeamIDs, blocked: blockedFolders(context)))
        if Task.isCancelled { return [] }
        progress(0.3, "Signatures des applications")
        groups.append(scanApplications(context: context))
        if Task.isCancelled { return [] }
        progress(0.45, "Extensions de navigateur")
        let safari = Extensions.safari(pluginKit: Shell.run("/usr/bin/pluginkit", ["-m", "-v", "-p", "com.apple.Safari.web-extension"]).stdout,
                                       context: context, excludedTeamIDs: excludedTeamIDs)
        groups += [Extensions.group(safari: safari, chrome: Extensions.chrome(context: context)),
                   Extensions.safariHomepage(context: context, fullDiskAccess: fullDiskAccess)]
        progress(0.55, Self.yaraAvailable == nil ? "Liste de hash locale" : "Règles XProtect (YARA)")
        groups += scanFiles(context: context)
        if Task.isCancelled { return [] }
        guard includePrivacy else { progress(1, "Terminé"); return groups }
        progress(0.85, "Vie privée")
        let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        let tcc = Privacy.permissions(context: context, systemDB: fullDiskAccess ? Privacy.systemTCCDatabase : nil)
        groups += [Browsers.scan(context: context, running: running), Privacy.cameraMicrophone(tcc), tcc,
                   Privacy.recentItems(context: context), WiFi.group(WiFi.known(), interface: WiFi.interfaceName())]
        progress(1, "Terminé")
        return groups
    }

    func scanCustom(context: ModuleContext, progress: @escaping ProgressHandler) -> [ResultGroup] {
        progress(0.1, "Analyse des éléments choisis")
        let roots = customRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let scan = fileScan(context: context)
        // Without a detector, expanding archives would only write to disk for nothing.
        let hits = scan.yara == nil && scan.hashes.isEmpty ? [] : scan.scan(roots: roots, archiveRoots: roots)
        let apps = roots.flatMap { r in r.pathExtension == "app" ? [r] : ((try? FileManager.default.contentsOfDirectory(at: r, includingPropertiesForKeys: nil)) ?? []) }
            .filter { $0.pathExtension == "app" }
        var group = hitGroup(hits, id: "prot.custom", title: "Analyse personnalisée",
                             subtitle: Self.yaraAvailable == nil ? "yara absent : seuls la liste de hash et les signatures des apps sont vérifiées" : "Règles XProtect, liste de hash et signatures",
                             context: context)
        group.items += appItems(apps, context: context)
        progress(1, "Terminé")
        return [group]
    }

    // MARK: Persistence

    struct LaunchItem {
        let plist: URL
        let label: String
        let target: URL?
        let system: Bool
    }

    static let launchDirs: [(String, Bool)] = [("~/Library/LaunchAgents", false), ("/Library/LaunchAgents", true), ("/Library/LaunchDaemons", true)]

    func launchItems(context: ModuleContext) -> [LaunchItem] {
        Self.launchDirs.flatMap { path, system in
            let dir = path.hasPrefix("~") ? context.home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.compactMap { Self.launchItem($0, system: system) }
        }
    }

    static func launchItem(_ f: URL, system: Bool) -> LaunchItem? {
        // No skip on a "com.apple." name: Apple installs nothing in ~/Library/LaunchAgents and adware borrows the prefix.
        // Apple's own jobs drop out in `persistenceItem` on their Apple signature.
        guard f.pathExtension == "plist",
              let data = try? Data(contentsOf: f),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let args = dict["ProgramArguments"] as? [String] ?? []
        var program = dict["Program"] as? String ?? args.first
        // For script interpreters, the interesting file is the script, not the interpreter.
        if let p = program, isInterpreter(p), let script = args.dropFirst().first(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }) {
            program = script
        }
        let target = program.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        return LaunchItem(plist: f, label: dict["Label"] as? String ?? f.deletingPathExtension().lastPathComponent, target: target, system: system)
    }

    /// Temporary and shared folders: an unsigned or broken program launched from there is selected by default.
    static func isSuspiciousLocation(_ url: URL, home: URL) -> Bool {
        let p = url.path
        return p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/private/var/tmp/") || p.hasPrefix("/Users/Shared/")
    }

    /// A hidden folder of the home folder (~/.local, ~/.nvm, ~/.cargo, ~/.bun…): developer tools live there,
    /// so a program found there is only "à vérifier", never selected by default.
    static func isHiddenHomeLocation(_ url: URL, home: URL) -> Bool {
        let p = url.path
        let rel = p.hasPrefix(home.path) ? String(p.dropFirst(home.path.count)) : p
        return rel.split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        let magic = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xFEEDFACF, 0xCFFAEDFE, 0xFEEDFACE, 0xCEFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }

    /// Folders a scan must not open without Full Disk Access (a stat or a signature check would show a prompt).
    func blockedFolders(_ context: ModuleContext) -> [String] {
        fullDiskAccess ? [] : FullDiskAccess.promptingFolders(home: context.home)
    }

    /// Why a launch item is reported and whether it is selected, or nil when it is not reported. Selected only in
    /// /tmp or /Users/Shared (`suspicious`); a hidden home folder (`hidden`) is "à vérifier".
    static func persistenceVerdict(_ sig: SignatureInfo, suspicious: Bool, hidden: Bool, machO: Bool) -> (reason: String, auto: Bool)? {
        let place = suspicious ? "emplacement suspect" : "dossier caché, à vérifier"
        switch sig.status {
        case .invalid:
            return ("Signature invalide" + (suspicious ? ", emplacement suspect" : ""), suspicious)
        case .unsigned:
            // Scripts are never signed; only Mach-O binaries are expected to be.
            if suspicious || hidden { return ("Non signé, \(place)", suspicious) }
            return machO ? ("Programme non signé", false) : nil
        case .valid:
            guard (suspicious || hidden) && !sig.isApple && !sig.isNotarized else { return nil }
            return ("Non notarisé, \(place)", false)
        }
    }

    func persistenceItem(_ li: LaunchItem, context: ModuleContext,
                         check: (URL) -> SignatureInfo = { CodeSignature.check($0, validateResources: false) }) -> ResultItem? {
        guard let target = li.target, !FullDiskAccess.isUnder(target.path, blockedFolders(context)),
              FileManager.default.fileExists(atPath: target.path), !context.isExcluded(li.plist) else { return nil }
        let sig = check(target)
        if let t = sig.teamID, excludedTeamIDs.contains(t) { return nil }
        guard let verdict = Self.persistenceVerdict(sig, suspicious: Self.isSuspiciousLocation(target, home: context.home),
                                                    hidden: Self.isHiddenHomeLocation(target, home: context.home),
                                                    machO: Self.isMachO(target)) else { return nil }
        var item = ResultItem(id: li.plist.path, name: li.label, detail: "\(ThreatType.suspicious.label) · \(verdict.reason) — \(target.path)",
                              url: li.plist, size: FileSizer.size(of: li.plist), symbol: "exclamationmark.triangle",
                              action: .custom(li.system ? "quarantine-launch-system" : "quarantine-launch-user"), autoSelect: verdict.auto)
        // A system job is moved by the administrator batch (`execute`).
        item.customNeedsAdmin = li.system
        return item
    }

    func scanPersistence(context: ModuleContext) -> ResultGroup {
        ResultGroup(id: "prot.persistence", title: "Lancement au démarrage suspect",
                    subtitle: "Agents et démons qui lancent un programme non signé ou mal signé", symbol: "bolt.badge.clock",
                    items: launchItems(context: context).compactMap { persistenceItem($0, context: context) })
    }

    // MARK: Applications

    func appItems(_ apps: [URL], context: ModuleContext) -> [ResultItem] {
        apps.compactMap { app in
            guard !context.isExcluded(app) else { return nil }
            let sig = CodeSignature.check(app, validateResources: false)
            guard sig.status != .valid, !(sig.teamID.map(excludedTeamIDs.contains) ?? false) else { return nil }
            return ResultItem(id: app.path, name: app.deletingPathExtension().lastPathComponent,
                              detail: sig.status == .invalid ? "Exécutable à la signature invalide (modifié ou corrompu)" : "Application non signée",
                              url: app, size: FileSizer.size(of: app), action: .custom("quarantine-file"), autoSelect: false)
        }
    }

    func scanApplications(context: ModuleContext) -> ResultGroup {
        var roots = [URL(fileURLWithPath: "/Applications"), context.home.appendingPathComponent("Applications")]
        if depth != .quick && fullDiskAccess { roots.append(context.home.appendingPathComponent("Downloads")) }
        let apps = roots.flatMap { ((try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" } }
        return ResultGroup(id: "prot.apps", title: "Applications à la signature douteuse",
                           subtitle: "À vérifier : une app non signée n'est pas forcément malveillante", symbol: "app.badge", items: appItems(apps, context: context))
    }

    // MARK: Files (YARA, hashes, archives)

    static func mailDownloads(home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"), home.appendingPathComponent("Library/Mail Downloads")]
    }

    /// Local external volumes up to 64 GB (no network shares, no disk images of the system).
    static func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeIsRootFileSystemKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).filter { v in
            guard let r = try? v.resourceValues(forKeys: Set(keys)) else { return false }
            return r.volumeIsInternal == false && r.volumeIsLocal == true && r.volumeIsRootFileSystem != true
                && Int64(r.volumeTotalCapacity ?? .max) <= maxExternalVolume
        }
    }

    /// Subfolders of `dir` except `skipping`: how a root is scanned "without" some of its folders (yara has no exclude option).
    static func children(of dir: URL, skipping: Set<String>) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !skipping.contains($0.lastPathComponent) }.sorted { $0.path < $1.path }
    }

    /// Cloud folders are never read by YARA: reading a placeholder downloads it.
    static let cloudFolders: Set<String> = ["Mobile Documents", "CloudStorage"]

    /// Scan roots. Quick: Application Support (user and system), Downloads, plus the shared and LaunchAgents
    /// folders. Balanced: + /Library (without launchd and Preferences), /Applications, ~/Library (without LaunchAgents,
    /// Preferences, Caches, Logs, Containers), ~/Applications. Deep: the same without the ~/Library exclusions, + Desktop
    /// and Documents. Persistence and processes are checked in every mode.
    func yaraTargets(context: ModuleContext) -> [URL] {
        let h = context.home
        let lib = h.appendingPathComponent("Library")
        let system = URL(fileURLWithPath: "/Library")
        var t = [h.appendingPathComponent("Downloads"), URL(fileURLWithPath: "/Users/Shared"), lib.appendingPathComponent("LaunchAgents"),
                 lib.appendingPathComponent("Application Support"), system.appendingPathComponent("Application Support")]
        let base: Set<String> = ["LaunchAgents", "Application Support"]
        switch depth {
        case .quick:
            break
        case .balanced:
            t += Self.children(of: system, skipping: ["LaunchAgents", "LaunchDaemons", "Preferences", "Application Support", "Apple"])
            t += [URL(fileURLWithPath: "/Applications"), h.appendingPathComponent("Applications")]
            t += Self.children(of: lib, skipping: base.union(["Preferences", "Caches", "Logs", "Containers"]).union(Self.cloudFolders))
        case .deep:
            t += Self.children(of: system, skipping: ["LaunchAgents", "LaunchDaemons", "Application Support", "Apple"])
            t += [URL(fileURLWithPath: "/Applications"), h.appendingPathComponent("Applications")]
            t += Self.children(of: lib, skipping: base.union(Self.cloudFolders))
            // Desktop and Documents synced by iCloud hold placeholders.
            t += ["Desktop", "Documents"].map { h.appendingPathComponent($0) }.filter { u in
                fullDiskAccess && (try? u.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem != true
            }
        }
        // Deep already covers ~/Library/Containers, Mail included.
        if scanMailAttachments && depth != .deep { t += Self.mailDownloads(home: h) }
        if fullDiskAccess && scanExternalDrives { t += Self.externalVolumes() }
        let blocked = blockedFolders(context)
        var seen = Set<String>()
        return t.filter { u in
            !FullDiskAccess.isUnder(u.path, blocked) && seen.insert(u.path).inserted
                && FileManager.default.fileExists(atPath: u.path) && !context.isExcluded(u)
        }
    }

    func archiveRoots(context: ModuleContext) -> [URL] {
        guard fullDiskAccess else { return [] }
        let h = context.home
        var r = [h.appendingPathComponent("Downloads")]
        if scanMailAttachments { r += Self.mailDownloads(home: h) }
        if depth == .deep { r += [h.appendingPathComponent("Desktop"), h.appendingPathComponent("Documents")] }
        return r
    }

    /// Parses `yara` output lines "RuleName /path/to/file".
    static func parseYARA(_ output: String) -> [(rule: String, path: String)] { FileScan.parseYARA(output) }

    func hitGroup(_ hits: [FileScan.Hit], id: String, title: String, subtitle: String, context: ModuleContext) -> ResultGroup {
        let items = hits.compactMap { h -> ResultItem? in
            let url = URL(fileURLWithPath: h.path)
            guard !context.isExcluded(url) else { return nil }
            if !excludedTeamIDs.isEmpty, let t = CodeSignature.check(url, validateResources: false).teamID, excludedTeamIDs.contains(t) { return nil }
            let inner = h.inner.map { " (dans l'archive : \($0))" } ?? ""
            return ResultItem(id: h.path, name: url.lastPathComponent, detail: "\(h.type.label) · \(h.source) \(h.rule)\(inner) — \(h.path)",
                              url: url, size: FileSizer.size(of: url), symbol: "ladybug", action: .custom("quarantine-file"), autoSelect: true)
        }
        return ResultGroup(id: id, title: title, subtitle: subtitle, symbol: "ladybug", items: items)
    }

    func scanFiles(context: ModuleContext) -> [ResultGroup] {
        let scan = fileScan(context: context)
        guard scan.yara != nil || !scan.hashes.isEmpty else {
            return [ResultGroup(id: "prot.yara", title: "Règles XProtect", subtitle: "yara absent : brew install yara pour activer ce scan", symbol: "doc.text.magnifyingglass")]
        }
        let hits = scan.scan(roots: yaraTargets(context: context), archiveRoots: archiveRoots(context: context))
        var groups = [hitGroup(hits.filter { $0.source == "Règle" }, id: "prot.yara", title: "Fichiers reconnus par XProtect",
                               subtitle: "Correspondances avec les règles YARA d'Apple, archives et installeurs compris", context: context)]
        if !scan.hashes.isEmpty {
            groups.append(hitGroup(hits.filter { $0.source != "Règle" }, id: "prot.hashes", title: "Fichiers de votre liste de hash",
                                   subtitle: "SHA-256 présents dans hashes.txt", context: context))
        }
        return groups
    }

    // MARK: Real-time checks

    /// Checks files reported by the monitor: launch plists with the persistence heuristics, other files with
    /// YARA, the hash list and archive expansion. Returns the threats found.
    /// Sure detections (rule or hash hits) apart from the heuristic ones (suspicious launch items).
    public func assess(_ urls: [URL], context: ModuleContext) -> (confirmed: [ResultItem], review: [ResultItem]) {
        var items: [ResultItem] = []
        var confirmed: [ResultItem] = []
        var files: [URL] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) && !context.isExcluded(url) {
            let dir = url.deletingLastPathComponent().lastPathComponent
            if dir == "LaunchAgents" || dir == "LaunchDaemons" {
                if let li = Self.launchItem(url, system: !url.path.hasPrefix(context.home.path)), let item = persistenceItem(li, context: context) { items.append(item) }
            } else {
                files.append(url)
            }
        }
        if !files.isEmpty {
            let archives = files.filter { ["zip", "pkg", "mpkg"].contains($0.pathExtension.lowercased()) }
            let scan = fileScan(context: context)
            if scan.yara != nil || !scan.hashes.isEmpty {
                confirmed = hitGroup(scan.scan(roots: files, archiveRoots: archives), id: "prot.monitor", title: "", subtitle: "", context: context).items
            }
        }
        return (confirmed, items)
    }

    // MARK: Execute

    public func appDependency(of item: ResultItem) -> AppDependency? {
        guard case .custom(let key) = item.action else { return nil }
        if key.hasPrefix(Extensions.chromeKeyPrefix) { return Browsers.dependency(key: Browsers.keyPrefix + key.dropFirst(Extensions.chromeKeyPrefix.count)) }
        return Browsers.dependency(key: key)
    }

    /// The program a launch plist runs, when it goes to the quarantine with the plist: it exists, lies
    /// outside the system folders and /Applications, is not a script interpreter and passes `SafeRemover`.
    static func quarantinableProgram(of plist: URL, remover: SafeRemover) -> URL? {
        guard let t = launchItem(plist, system: false)?.target else { return nil }
        let p = t.path
        guard !p.contains("/../"), !isInterpreter(p), !Processes.systemPrefixes.contains(where: p.hasPrefix),
              (try? FileManager.default.attributesOfItem(atPath: p)) != nil else { return nil }
        let target = Processes.removalTarget(p)
        return (try? remover.check(target)) == nil ? nil : target
    }

    /// Quarantines a launch agent's program as the user; a line of the log either way.
    /// `linkedTo`: the quarantine entry of its plist, restored with it.
    func quarantineProgram(_ program: URL, of item: ResultItem, linkedTo: String?) -> String {
        let stopped = Processes.terminate(runningFrom: program)
        do {
            try quarantine.add(program, reason: "Programme lancé par \(item.name)", linkedTo: linkedTo)
            return "Quarantaine : \(program.path)" + (stopped > 0 ? " (\(stopped) processus arrêté(s))" : "")
        } catch {
            return "Programme non mis en quarantaine (\(program.path)) : \(error.localizedDescription)"
        }
    }

    public func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport {
        var report = ExecutionReport()
        // Commands (tccutil resets, settings links) go through the executor with the root batch.
        var adminItems = items.filter { if case .command = $0.action { true } else { false } }
        let uid = getuid()
        var clearedRecent = false
        // Root moves waiting for the batch, by batch item id: the manifest is written only once the move succeeded.
        var pending: [String: (entry: String, path: String, reason: String, owner: String)] = [:]
        // User-owned programs of system jobs, quarantined once their plist is gone.
        var programsAfterBatch: [(owner: String, program: URL, item: ResultItem, entry: String)] = []
        for (i, item) in items.enumerated() {
            guard case .custom(let key) = item.action else { continue }
            if Task.isCancelled {
                for rest in items[i...] { if case .custom = rest.action { report.failures.append((rest.id, ExecutionProgress.stoppedReason)) } }
                break
            }
            ExecutionProgress.onItem?(item)
            if context.dryRun { report.processed.append(item.id); continue }
            if key == Cron.removeKey {
                do {
                    let line = String(item.id.dropFirst(Cron.idPrefix.count))
                    try Cron.remove(line, backupDir: quarantine.root.deletingLastPathComponent().appendingPathComponent("Crontab"))
                    report.processed.append(item.id)
                    report.log.append("Crontab : ligne retirée « \(Cron.excerpt(line)) »")
                } catch {
                    report.failures.append((item.id, error.localizedDescription))
                }
                continue
            }
            guard let url = item.url else { continue }
            do {
                try context.remover.check(url)
                switch key {
                case "quarantine-launch-user":
                    let program = Self.quarantinableProgram(of: url, remover: context.remover)
                    Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", url.path])
                    let entry = try quarantine.add(url, reason: item.detail ?? "")
                    if let program { report.log.append(quarantineProgram(program, of: item, linkedTo: entry.id)) }
                case "quarantine-file":
                    let stopped = Processes.terminate(runningFrom: url)
                    if stopped > 0 { report.log.append("\(stopped) processus arrêté(s) : \(url.path)") }
                    try quarantine.add(url, reason: item.detail ?? "")
                case _ where key.hasPrefix(Extensions.chromeKeyPrefix):
                    let bundleID = String(key.dropFirst(Extensions.chromeKeyPrefix.count))
                    if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                        throw RemovalError.failed(item.name, "quittez le navigateur puis réessayez")
                    }
                    try quarantine.add(url, reason: item.detail ?? "")
                case _ where key.hasPrefix(Browsers.keyPrefix):
                    try Browsers.clear(item, key: key, remover: context.remover)
                    report.processed.append(item.id)
                    report.log.append("\(item.name) effacé : \(url.path)")
                    continue
                case Privacy.removeRecentList:
                    if let f = context.remover.remove([url], mode: .trash).failures.first { throw RemovalError.failed(url.path, f.1) }
                    clearedRecent = true
                    report.processed.append(item.id)
                    report.log.append("Corbeille : \(url.path)")
                    continue
                case "quarantine-launch-system":
                    // Root-owned plist: bootout in its own domain and move it into the root zone behind the admin prompt.
                    let program = Self.quarantinableProgram(of: url, remover: context.remover)
                    let id = UUID().uuidString
                    let cmd = try quarantine.adminAddCommand(url, id: id, domain: Quarantine.launchdDomain(url.path, uid: uid))
                    var admin = item
                    admin.action = .command(executable: cmd[0], arguments: Array(cmd.dropFirst()), admin: true)
                    adminItems.append(admin)
                    pending[item.id] = (id, url.path, item.detail ?? "", item.id)
                    if let program {
                        if FileManager.default.isDeletableFile(atPath: program.path) {
                            programsAfterBatch.append((item.id, program, item, id))
                        } else {
                            let pid = UUID().uuidString
                            guard let pcmd = try? quarantine.adminAddCommand(program, id: pid, domain: nil) else { continue }
                            let sub = ResultItem(id: item.id + "#program", name: program.lastPathComponent, url: program,
                                                 action: .command(executable: pcmd[0], arguments: Array(pcmd.dropFirst()), admin: true))
                            adminItems.append(sub)
                            pending[sub.id] = (pid, program.path, "Programme lancé par \(item.name)", item.id)
                        }
                    }
                    continue
                default:
                    throw RemovalError.failed(url.path, "action inconnue \(key)")
                }
                report.processed.append(item.id)
                report.log.append("Quarantaine : \(url.path)")
            } catch {
                report.failures.append((item.id, error.localizedDescription))
            }
        }
        // sharedfilelistd keeps the lists in memory and would write them back.
        if clearedRecent { Shell.run("/usr/bin/killall", ["sharedfilelistd"]) }
        guard !adminItems.isEmpty else { return report }
        // Runs now, outside any Vibe Check collector: the manifests are written only once the root move succeeded.
        let r = ActionExecutor.$adminCollector.withValue(nil) { ActionExecutor(remover: context.remover).run(adminItems) }
        report.freedBytes += r.freedBytes
        report.log += r.log
        for id in r.processed {
            guard let p = pending[id] else { report.processed.append(id); continue }
            if !context.dryRun {
                // A program records the entry of its plist, so that restoring the plist brings it back too.
                let link = p.owner == id ? nil : pending[p.owner]?.entry
                do { try quarantine.recordAdmin(id: p.entry, originalPath: p.path, reason: p.reason, linkedTo: link) } catch {
                    report.log.append("Manifeste de quarantaine non écrit pour \(p.path) : \(error.localizedDescription)")
                }
            }
            if p.owner == id {
                report.processed.append(id)
                report.log.append("Quarantaine (administrateur) : \(p.path)")
            }
        }
        for f in r.failures {
            if let p = pending[f.id], p.owner != f.id {
                report.log.append("Programme non mis en quarantaine (\(p.path)) : \(f.reason)")
            } else {
                report.failures.append(f)
            }
        }
        for p in programsAfterBatch where r.processed.contains(p.owner) && !context.dryRun {
            report.log.append(quarantineProgram(p.program, of: p.item, linkedTo: p.entry))
        }
        return report
    }
}
