import AppKit
import Foundation
import VibeCleanerCore

// vibeclean list | scan <module> [--all] | clean <module> [--apply] | quarantine list|restore <id>|purge <id>
// `clean` is a dry run unless --apply is passed; it acts on the default (smart) selection.
let args = Array(CommandLine.arguments.dropFirst())

func module(_ id: String) -> any ScanModule {
    guard let m = Catalog.modules.first(where: { $0.id == id }) else {
        FileHandle.standardError.write("module inconnu : \(id)\n".data(using: .utf8)!)
        exit(2)
    }
    return m
}

/// The app's settings (`Prefs` keys), read from its own domain so that the CLI honours the same ignore list.
func appDefaults() -> UserDefaults? { UserDefaults(suiteName: "ai.flowpace.vibecleaner") }

func lines(_ key: String) -> [String] {
    (appDefaults()?.string(forKey: key) ?? "").split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

func flag(_ key: String, default value: Bool) -> Bool { appDefaults()?.object(forKey: key) as? Bool ?? value }

/// Ignored paths, plus the bundles and per-bundle-id folders of ignored apps (same list as `Prefs.context()`).
func exclusions() -> [String] {
    lines("exclusions") + lines("excludedBundleIDs").flatMap { id in
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path)
            + ["Caches", "Logs", "Containers", "HTTPStorages", "WebKit", "Application Support"].map { "~/Library/\($0)/\(id)" }
            + ["~/Library/Preferences/\(id).plist", "~/Library/Saved Application State/\(id).savedState"]
    }
}

/// Protection with the app's settings; folders that would show a permission prompt are read only with Full Disk Access.
func configured(_ m: any ScanModule) -> any ScanModule {
    guard var p = m as? ProtectionModule else { return m }
    p.depth = ProtectionModule.ScanDepth(rawValue: appDefaults()?.string(forKey: "protectionDepth") ?? "") ?? .balanced
    p.excludedTeamIDs = Set(lines("excludedTeamIDs"))
    p.scanDiskImages = flag("protectionScanDMG", default: false)
    p.scanArchives = flag("protectionScanArchives", default: false)
    p.scanMailAttachments = flag("protectionScanMail", default: true)
    p.scanExternalDrives = flag("protectionScanUSB", default: false)
    p.fullDiskAccess = FullDiskAccess.isGranted
    return p
}

func printGroup(_ g: ResultGroup, _ sel: Set<String>, indent: String = "", items: Bool) {
    print("\(indent)\(g.title)  \(FileSizer.format(g.totalSize))  (\(g.allItems.count), sélection \(FileSizer.format(g.selectedSize(sel))))")
    for s in g.groups { printGroup(s, sel, indent: indent + "  ", items: items) }
    guard items else { return }
    for i in g.items.sorted(by: { $0.size > $1.size }) {
        print("\(indent)  \(sel.contains(i.id) ? "[x]" : "[ ]") \(FileSizer.format(i.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(i.detail.map { "\(i.name) — \($0)" } ?? i.name)")
    }
}

switch args.first {
case "list":
    for m in Catalog.modules { print("\(m.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(m.title)") }
case "scan", "clean":
    guard args.count >= 2 else { print("usage: vibeclean scan|clean <module>"); exit(2) }
    let m = configured(module(args[1]))
    let apply = args.contains("--apply")
    // Run by a script or another program, a real cleaning needs a second, explicit word: nobody reviews it.
    if args[0] == "clean", apply, isatty(STDIN_FILENO) == 0, !args.contains("--yes") {
        FileHandle.standardError.write("Sans terminal interactif, ajoutez --yes à --apply pour confirmer le nettoyage.\n".data(using: .utf8)!)
        exit(2)
    }
    let ctx = ModuleContext(dryRun: !apply, exclusions: exclusions())
    let groups = await m.scan(context: ctx) { f, step in
        FileHandle.standardError.write("\r\(Int(f * 100))% \(step.prefix(70))".padding(toLength: 80, withPad: " ", startingAt: 0).data(using: .utf8)!)
    }.map { $0.pruned() }.filter { !$0.isEmpty }
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    let sel = ResultQueries.initialSelection(groups)
    for g in groups { printGroup(g, sel, items: args.contains("--all")) }
    if args[0] == "clean" {
        // Never remove every copy of a duplicate set or similar-image series (the app asks first; the CLI refuses).
        let atRisk = ResultQueries.fullySelectedCopySets(groups, selection: sel)
        if !atRisk.isEmpty {
            FileHandle.standardError.write(("Nettoyage refusé : la sélection supprimerait tous les exemplaires de "
                + atRisk.map { "« \($0.title) »" }.joined(separator: ", ") + ". Rien n'a été modifié.\n").data(using: .utf8)!)
            exit(1)
        }
        let items = groups.flatMap(\.allItems).filter { sel.contains($0.id) }
        let r = await m.execute(items, context: ctx)
        print("\(apply ? "" : "[simulation] ")\(r.processed.count) traités, \(FileSizer.format(r.freedBytes)), \(r.failures.count) erreurs")
        for f in r.failures { print("  ! \(f.id): \(f.reason)") }
    }
case "quarantine":
    let q = Quarantine()
    switch (args.dropFirst().first, args.count > 2 ? args[2] : nil) {
    case ("list", _), (nil, _):
        let entries = q.list()
        if entries.isEmpty { print("La quarantaine est vide.") }
        for e in entries {
            print("\(e.id)  \(e.date.formatted(date: .abbreviated, time: .shortened))  \(e.originalPath)  — \(e.reason)")
        }
    case ("restore", let id?), ("purge", let id?):
        do {
            if args[1] == "restore" { try q.restore(id); print("Restauré.") } else { try q.purge(id); print("Supprimé définitivement.") }
        } catch {
            FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    default:
        print("usage: vibeclean quarantine list | restore <id> | purge <id>"); exit(2)
    }
default:
    print("usage: vibeclean list | scan <module> [--all] | clean <module> [--apply] | quarantine list|restore <id>|purge <id>")
}
