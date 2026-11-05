/// All modules in sidebar order (Radar is a dedicated view inserted by the app before Cloud).
public enum Catalog {
    public static var modules: [any ScanModule] {
        [CleanupModule(), ProtectionModule(), PerformanceModule(), ApplicationsModule(), ClutterModule(), CloudModule()]
    }

    /// Modules aggregated by Vibe Check: Cleanup, Protection, Performance, Applications, Fouillis.
    public static var vibeCheck: [any ScanModule] {
        [CleanupModule(), ProtectionModule(), PerformanceModule(autoSelectsPasswordTasks: false, vibeCheckSubset: true), ApplicationsModule(),
         ClutterModule(options: .vibeCheck)]
    }
}
