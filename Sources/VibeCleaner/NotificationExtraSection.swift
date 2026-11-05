import SwiftUI
import VibeCleanerCore

/// Extra alert settings, appended to Réglages > Notifications.
struct NotificationExtraSection: View {
    @AppStorage(Prefs.alertTrashedApps) private var trashedApps = true
    @AppStorage(Prefs.alertAccessoryBattery) private var accessoryBattery = true
    @AppStorage(Prefs.alertDriveConnected) private var driveConnected = true
    @AppStorage(Prefs.alertExternalLow) private var externalLow = true

    var body: some View {
        Section("Applications") {
            Toggle("Prévenir quand une app est mise à la corbeille sans ses fichiers liés", isOn: $trashedApps)
            Text("La détection des apps qui ne répondent plus n'est pas proposée : macOS ne la permet qu'avec une API privée ou l'autorisation Accessibilité.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Appareils") {
            Toggle("Prévenir quand la batterie d'un accessoire passe sous \(AlertSettings.accessoryLowPercent) %", isOn: $accessoryBattery)
            Toggle("Prévenir quand un disque est connecté", isOn: $driveConnected)
            Toggle("Prévenir quand un disque externe est presque plein (moins de 10 % libres)", isOn: $externalLow)
        }
    }
}
