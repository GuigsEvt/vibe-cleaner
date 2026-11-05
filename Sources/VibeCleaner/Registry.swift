import VibeCleanerCore

/// Sidebar order: Vibe Check, Cleanup, Protection, Performance, Applications, Fouillis, Radar.
enum Registry {
    static var entries: [ModuleEntry] {
        let modules = Catalog.modules
        var list = modules.map {
            ModuleEntry(id: $0.id, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol, actionTitle: $0.actionTitle, modules: [$0])
        }
        list.insert(ModuleEntry(id: "vibecheck", title: "Vibe Check", subtitle: "Analyse complète du Mac en un clic : nettoyage, protection, performance, applications et fouillis.",
                                symbol: "laptopcomputer", actionTitle: "Lancer", modules: Catalog.vibeCheck), at: 0)
        let lens = ModuleEntry(id: "radar", title: "Radar", subtitle: "", symbol: "circle.hexagongrid", actionTitle: "", modules: [])
        list.insert(lens, at: list.firstIndex { $0.id == "cloud" } ?? list.endIndex)
        return list
    }
}
