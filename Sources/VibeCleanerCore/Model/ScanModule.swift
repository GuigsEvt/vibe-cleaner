import Foundation

/// Reports scan progress: fraction in 0...1 and the step being scanned.
public typealias ProgressHandler = @Sendable (Double, String) -> Void

public struct ModuleContext: Sendable {
    public var dryRun: Bool
    public var exclusions: [String]
    public var home: URL

    public init(dryRun: Bool = false, exclusions: [String] = [], home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.dryRun = dryRun
        self.exclusions = exclusions
        self.home = home
    }

    public var remover: SafeRemover { SafeRemover(dryRun: dryRun, userExclusions: exclusions, home: home.path) }

    /// True when a path is covered by the user's ignore list (same normalisation as `SafeRemover.check`).
    public func isExcluded(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return exclusions.contains { ex in
            let e = URL(fileURLWithPath: (ex as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            return path == e || path.hasPrefix(e + "/")
        }
    }
}

/// One sidebar module: scans into result groups, then executes the user's selection.
public protocol ScanModule: Sendable {
    var id: String { get }
    var title: String { get }
    var subtitle: String { get }
    var symbol: String { get }
    /// Label of the main action button ("Nettoyer", "Supprimer", "Lancer"...).
    var actionTitle: String { get }

    func scan(context: ModuleContext, progress: @escaping ProgressHandler) async -> [ResultGroup]
    func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport
    /// The app that must be closed before `item` can be processed, if any.
    func appDependency(of item: ResultItem) -> AppDependency?
}

public extension ScanModule {
    var actionTitle: String { "Nettoyer" }

    func execute(_ items: [ResultItem], context: ModuleContext) async -> ExecutionReport {
        ActionExecutor(remover: context.remover).run(items)
    }
}
