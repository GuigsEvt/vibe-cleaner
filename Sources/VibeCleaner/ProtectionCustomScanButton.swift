import SwiftUI
import VibeCleanerCore

/// "Analyser un dossier…" on the Protection intro: pick or drop folders and files, then scan only those.
struct ProtectionCustomScanButton: View {
    let run: ModuleRun
    @State private var targeted = false

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = true
            panel.prompt = "Analyser"
            if panel.runModal() == .OK { scan(panel.urls) }
        } label: {
            Label("Analyser un dossier…", systemImage: "folder.badge.questionmark")
        }
        .buttonStyle(GlassButtonStyle(tint: Theme.accent("protection")))
        .help("Ou déposez ici des dossiers et des fichiers")
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            scan(files)
            return true
        } isTargeted: { targeted = $0 }
        .overlay { if targeted { Capsule().strokeBorder(Theme.accent("protection"), lineWidth: 2).padding(-3) } }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private func scan(_ urls: [URL]) {
        ProtectionCustomScan.pending = urls
        run.requestScan()
    }
}
