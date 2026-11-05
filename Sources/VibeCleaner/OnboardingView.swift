import Combine
import SwiftUI
import UserNotifications

/// First launch: welcome, Full Disk Access with live status, notifications.
struct OnboardingView: View {
    let finish: () -> Void
    @State private var step: Int
    @State private var hasFDA = Permissions.hasFullDiskAccess
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(step: Int = 0, finish: @escaping () -> Void) {
        self.finish = finish
        _step = State(initialValue: step)
    }

    private var tint: Color { Theme.accent("vibecheck") }

    var body: some View {
        VStack(spacing: DS.Space.l) {
            dots
            Group {
                switch step {
                case 0:
                    page("hand.wave", "Bienvenue dans Vibe Cleaner",
                         "Analysez votre Mac, puis choisissez ce qui part. Rien n'est supprimé sans votre accord, et presque tout passe par la Corbeille.")
                    Button("Commencer") { advance(1) }.keyboardShortcut(.defaultAction)
                        .buttonStyle(GlassButtonStyle(tint: tint, prominent: true)).entrance(3)
                case 1:
                    if hasFDA {
                        page("checkmark.shield", "Accès complet au disque accordé", "Vibe Cleaner peut analyser tous vos dossiers.")
                        Button("Continuer") { advance(2) }.keyboardShortcut(.defaultAction)
                            .buttonStyle(GlassButtonStyle(tint: tint, prominent: true)).entrance(3)
                    } else {
                        page("lock.shield", "Accordez l'accès complet au disque",
                             "Il permet de trouver plus de fichiers inutiles, de vérifier les menaces partout et de gérer les traces de navigation. Activez Vibe Cleaner dans Réglages Système, cet écran se met à jour tout seul.")
                        HStack(spacing: DS.Space.s) {
                            Button("Plus tard") { advance(2) }.buttonStyle(GlassButtonStyle())
                            Button("Ouvrir les Réglages") { Permissions.openFullDiskAccessSettings() }.keyboardShortcut(.defaultAction)
                                .buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
                        }
                        .entrance(3)
                    }
                default:
                    page("bell.badge", "Restez informé",
                         "Vibe Cleaner peut vous prévenir quand le disque est presque plein, quand la corbeille déborde ou quand il est temps de lancer Smart\u{00A0}Care.")
                    HStack(spacing: DS.Space.s) {
                        Button("Plus tard", action: finish).buttonStyle(GlassButtonStyle())
                        Button("Autoriser les notifications") {
                            if AlertCenter.isAvailable {
                                Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); finish() }
                            } else { finish() }
                        }.keyboardShortcut(.defaultAction)
                            .buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
                    }
                    .entrance(3)
                }
            }
            // A new step replays the entrances.
            .id("\(step)-\(hasFDA)")
        }
        .padding(DS.Space.xxl)
        .frame(width: 540, height: 480)
        .background(SheetBackground(tint: tint))
        .onReceive(poll) { _ in if step == 1 { hasFDA = Permissions.hasFullDiskAccess } }
    }

    private func advance(_ next: Int) {
        withAnimation(DS.spring) { step = next }
    }

    /// Progress as three capsules, the current one stretched and lit.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Capsule().fill(i == min(step, 2) ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.2)))
                    .frame(width: i == min(step, 2) ? 22 : 7, height: 7)
            }
        }
        .animation(DS.spring, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Étape \(min(step, 2) + 1) sur 3")
    }

    @ViewBuilder private func page(_ symbol: String, _ title: String, _ text: String) -> some View {
        MacHero(tint: tint, symbol: symbol, width: 210).padding(.vertical, DS.Space.s).entrance(0)
        VStack(spacing: DS.Space.s) {
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity)
        .glass(tint: tint, radius: DS.Radius.tile)
        .entrance(1)
        Spacer(minLength: 0)
    }
}
