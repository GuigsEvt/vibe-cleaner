import SwiftUI
import VibeCleanerCore

/// Protection settings. The scan mode stays in the Analyse tab.
struct ProtectionSettingsSection: View {
    @AppStorage(Prefs.protectionMonitorEnabled) private var monitor = true
    @AppStorage(Prefs.protectionBackgroundScan) private var background = true
    @AppStorage(Prefs.protectionScanDMG) private var dmg = false
    @AppStorage(Prefs.protectionScanArchives) private var archives = false
    @AppStorage(Prefs.protectionScanMail) private var mail = true
    @AppStorage(Prefs.protectionScanUSB) private var usb = false

    var body: some View {
        Section("Surveillance") {
            Toggle("Surveiller les menaces en temps réel", isOn: $monitor)
            Text("Vérifie les nouveaux agents de lancement et, avec l'accès complet au disque, les fichiers téléchargés, tant que Vibe Cleaner est ouvert.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Rechercher les menaces en arrière-plan (analyse rapide quotidienne)", isOn: $background)
        }
        Section("Options d'analyse") {
            Toggle("Décompresser les installeurs PKG pour les analyser (dans le dossier temporaire)", isOn: $dmg)
            Toggle("Décompresser les archives ZIP pour les analyser (dans le dossier temporaire)", isOn: $archives)
            Toggle("Analyser les pièces jointes Mail", isOn: $mail)
            Toggle("Analyser les disques externes (64 Go au plus)", isOn: $usb)
            Text("Les images disque ne sont jamais montées ; archives et installeurs sont dépliés dans un dossier temporaire supprimé aussitôt. Le mode d'analyse se règle dans l'onglet Analyse.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Liste de hash locale") {
            Text("Ajoutez vos propres empreintes SHA-256, une par ligne (suivie d'un nom si besoin), dans hashes.txt.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Afficher hashes.txt dans le Finder") {
                let file = HashList.file(home: URL(fileURLWithPath: NSHomeDirectory()))
                if !FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? "# SHA-256 [nom], une empreinte par ligne\n".write(to: file, atomically: true, encoding: .utf8)
                }
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
    }
}
