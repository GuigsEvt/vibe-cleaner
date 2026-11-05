import AppIntents
import VibeCleanerCore

/// An app that Vibe Cleaner can uninstall; the id is the bundle path.
struct InstalledAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Application", synonyms: ["App", "Programme", "Logiciel"])
    static let defaultQuery = InstalledAppQuery()

    let id: String
    @Property(title: "Nom") var name: String
    @Property(title: "Emplacement") var path: String

    init(_ app: InstalledApp) {
        id = app.url.path
        name = app.name
        path = app.url.path
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(path)", image: .init(systemName: "app"))
    }
}

/// Search and suggestions over the removable apps of /Applications and ~/Applications (read only),
/// without the apps the user excluded (the action would refuse them).
struct InstalledAppQuery: EntityStringQuery {
    private func apps() -> [InstalledApp] {
        let context = Prefs.context()
        return ApplicationsModule().removableApps().filter { !context.isExcluded($0.url) }
    }

    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        let ids = Set(identifiers)
        return apps().filter { ids.contains($0.url.path) }.map(InstalledAppEntity.init)
    }

    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        apps().filter { $0.name.localizedStandardContains(string) || ($0.bundleID?.localizedStandardContains(string) ?? false) }
            .map(InstalledAppEntity.init)
    }

    func suggestedEntities() async throws -> [InstalledAppEntity] {
        apps().map(InstalledAppEntity.init)
    }
}
