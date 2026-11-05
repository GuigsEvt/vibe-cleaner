import Foundation

/// Xcode junk.
enum XcodeScanner {
    static let keptDerived: Set<String> = ["ModuleCache.noindex", "SymbolCache.noindex", "ModuleCache"]

    /// "MyApp-abcdefghijk" → "MyApp".
    static func derivedDataName(_ folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-"), dash != folder.startIndex else { return folder }
        return String(folder[..<dash])
    }

    static func scan(_ s: JunkScope) -> ResultGroup {
        let xcode = s.lib("Developer/Xcode")
        var g = ResultGroup(id: "cleanup.system.xcode", title: "Xcode",
                            subtitle: "Données de compilation, archives, prise en charge des appareils et simulateurs", symbol: "hammer.circle")
        func sub(_ id: String, _ title: String, _ items: [ResultItem]) {
            if !items.isEmpty { g.groups.append(ResultGroup(id: "\(g.id).\(id)", title: title, items: items)) }
        }

        sub("derived", "DerivedData", Junk.children(xcode.appendingPathComponent("DerivedData")).compactMap { url in
            let name = url.lastPathComponent
            return s.item(url, name: keptDerived.contains(name) ? name : derivedDataName(name), mode: .permanent, auto: !keptDerived.contains(name))
        })

        let archives = Junk.children(xcode.appendingPathComponent("Archives")).flatMap { Junk.children($0) }
            .filter { $0.pathExtension == "xcarchive" && Junk.exists($0.appendingPathComponent("Info.plist")) }
        sub("archives", "Archives", archives.compactMap { url in
            let info = Junk.plist(url.appendingPathComponent("Info.plist")) ?? [:]
            let date = info["CreationDate"] as? Date ?? Junk.created(url)
            return s.item(url, name: info["Name"] as? String ?? url.deletingPathExtension().lastPathComponent,
                          detail: "Archive du \(Junk.format(date))", mode: .trash, auto: false)
        })

        sub("deviceLogs", "Journaux des appareils iOS",
            [s.item(xcode.appendingPathComponent("iOS Device Logs"), name: "iOS Device Logs", mode: .trash)].compactMap { $0 })
        for (id, folder) in [("iosSupport", "iOS DeviceSupport"), ("macSupport", "macOS DeviceSupport")] {
            sub(id, folder, Junk.children(xcode.appendingPathComponent(folder)).compactMap {
                s.item($0, detail: "Symboles copiés depuis un appareil (recopiés à la prochaine connexion)", mode: .permanent, auto: false)
            })
        }
        sub("docs", "Cache de documentation", Junk.children(xcode.appendingPathComponent("DocumentationCache")).flatMap { Junk.children($0) }
            .compactMap { s.item($0, mode: .permanent, auto: false) })

        var moduleCaches: [URL] = []
        if s.system, let darwin = Junk.confstrPath(_CS_DARWIN_USER_CACHE_DIR) {
            moduleCaches = Junk.children(darwin).filter { $0.lastPathComponent.hasPrefix("org.llvm.clang") }
                .map { $0.appendingPathComponent("ModuleCache") }.filter(Junk.exists)
        }
        sub("moduleCaches", "Caches de modules", moduleCaches.compactMap { s.item($0, name: "clang — ModuleCache", mode: .permanent, auto: false) })
        sub("simCaches", "Caches CoreSimulator",
            [s.item(s.lib("Developer/CoreSimulator/Caches"), name: "CoreSimulator Caches", mode: .permanent, auto: false)].compactMap { $0 })

        if s.system, let item = unavailableSimulators(s) { sub("simulators", "Simulateurs indisponibles", [item]) }
        sub("runtimes", "Runtimes de simulateurs", simulatorRuntimes(s))
        return g
    }

    // MARK: Simulator runtimes

    static let imagesPlist = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Images/images.plist")

    struct RuntimeImage: Equatable { let uuid: String; let identifier: String; let name: String; let image: URL? }

    /// Disk images registered with CoreSimulator (`images.plist`, read as a file: no `simctl` during a scan).
    static func runtimeImages(_ plist: [String: Any]) -> [RuntimeImage] {
        func url(_ any: Any?) -> URL? { ((any as? [String: Any])?["relative"] as? String).flatMap(URL.init(string:)) }
        return (plist["images"] as? [[String: Any]] ?? []).compactMap { image in
            guard let uuid = image["uuid"] as? String, let info = image["runtimeInfo"] as? [String: Any],
                  let id = info["bundleIdentifier"] as? String else { return nil }
            let bundle = url(info["bundlePath"])?.deletingPathExtension().lastPathComponent
            let name = [bundle ?? id.components(separatedBy: ".").last ?? id, (info["build"] as? String).map { "(\($0))" }]
                .compactMap { $0 }.joined(separator: " ")
            return RuntimeImage(uuid: uuid, identifier: id, name: name, image: url(image["sourceURL"]) ?? url(image["path"]))
        }
    }

    /// Runtime identifier → number of simulators using it, from each `device.plist`.
    static func runtimeUsage(in devices: URL) -> [String: Int] {
        let dirs = (try? Junk.fm.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? []
        var out: [String: Int] = [:]
        for d in dirs {
            if let runtime = NSDictionary(contentsOf: d.appendingPathComponent("device.plist"))?["runtime"] as? String { out[runtime, default: 0] += 1 }
        }
        return out
    }

    /// Downloaded runtimes, never selected. Disk images are removed by `simctl runtime delete <uuid>`
    /// at execution time (the documented way: it also unregisters the image); legacy `.simruntime` bundles are files.
    static func simulatorRuntimes(_ s: JunkScope) -> [ResultItem] {
        let usage = runtimeUsage(in: s.lib("Developer/CoreSimulator/Devices"))
        func used(_ id: String) -> String {
            let n = usage[id] ?? 0
            return n == 0 ? "Aucun simulateur ne l'utilise" : "Utilisé par \(n) simulateur(s)"
        }
        var items: [ResultItem] = []
        if s.system, let plist = Junk.plist(imagesPlist) {
            for r in runtimeImages(plist) where !(r.image.map(s.context.isExcluded) ?? false) {
                items.append(ResultItem(id: "cleanup.xcode.runtime.\(r.uuid)", name: r.name, detail: "\(used(r.identifier)) — \(r.identifier)",
                                        url: r.image, size: r.image.map(FileSizer.size(of:)) ?? 0, symbol: "iphone.gen3",
                                        action: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", r.uuid], admin: false),
                                        autoSelect: false))
            }
        }
        var bundleRoots = [s.lib("Developer/CoreSimulator/Profiles/Runtimes")]
        if s.system { bundleRoots.append(URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/Runtimes")) }
        for bundle in bundleRoots.flatMap({ Junk.children($0) }) where bundle.pathExtension == "simruntime" {
            let id = Junk.plist(bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String ?? ""
            if let item = s.item(bundle, name: bundle.deletingPathExtension().lastPathComponent, detail: "\(used(id)) — \(bundle.path)",
                                 mode: .trash, auto: false) { items.append(item) }
        }
        return items
    }

    /// Identifiers of installed simulator runtimes, read from the runtime bundles on disk.
    /// Running `xcrun simctl` during a scan can trigger Xcode's first-launch installer and an admin prompt.
    static func installedRuntimes() -> Set<String> {
        let fm = Junk.fm
        var roots = ["/Library/Developer/CoreSimulator/Profiles/Runtimes"]
        let volumes = "/Library/Developer/CoreSimulator/Volumes"
        for v in (try? fm.contentsOfDirectory(atPath: volumes)) ?? [] {
            roots.append("\(volumes)/\(v)/Library/Developer/CoreSimulator/Profiles/Runtimes")
        }
        var ids: Set<String> = []
        for root in roots {
            for b in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where b.hasSuffix(".simruntime") {
                if let info = NSDictionary(contentsOfFile: "\(root)/\(b)/Contents/Info.plist"),
                   let id = info["CFBundleIdentifier"] as? String { ids.insert(id) }
            }
        }
        return ids
    }

    /// Simulators whose runtime is no longer installed (what `simctl` reports as unavailable).
    static func unavailableDevices(in devices: URL, runtimes: Set<String>) -> [(udid: String, name: String)] {
        guard !runtimes.isEmpty else { return [] }   // detection failed: never guess
        let dirs = (try? Junk.fm.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let plist = NSDictionary(contentsOf: d.appendingPathComponent("device.plist")),
                  let runtime = plist["runtime"] as? String, !runtimes.contains(runtime) else { return nil }
            return (d.lastPathComponent, plist["name"] as? String ?? d.lastPathComponent)
        }
    }

    static func unavailableSimulators(_ s: JunkScope) -> ResultItem? {
        let base = s.lib("Developer/CoreSimulator/Devices")
        let devices = unavailableDevices(in: base, runtimes: installedRuntimes())
        guard !devices.isEmpty else { return nil }
        let size = devices.reduce(Int64(0)) { $0 + FileSizer.size(of: base.appendingPathComponent($1.udid)) }
        return unavailableItem(devices, base: base, size: size)
    }

    /// Deletes exactly the simulators shown, by UDID (`delete unavailable` would also take ones that became
    /// unavailable after the scan). Never selected: a simulator holds app data and its runtime may be reinstalled.
    static func unavailableItem(_ devices: [(udid: String, name: String)], base: URL, size: Int64) -> ResultItem {
        ResultItem(id: "cleanup.xcode.simulators.unavailable", name: "\(devices.count) simulateur(s) indisponible(s)",
                   detail: devices.map(\.name).joined(separator: ", "), url: base, size: size, symbol: "iphone.slash",
                   action: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete"] + devices.map(\.udid), admin: false),
                   autoSelect: false)
    }
}
