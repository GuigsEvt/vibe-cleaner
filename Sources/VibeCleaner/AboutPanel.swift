import AppKit
import SwiftUI

/// The About window: who made the app, that it is free, open source and vibe coded, and that it comes without warranty.
/// Our own window rather than the standard panel, whose credits area has a fixed height and scrolls.
enum AboutPanel {
    static let sourceURL = URL(string: "https://github.com/GuigsEvt/vibe-cleaner")!
    static let authorURL = URL(string: "https://github.com/GuigsEvt")!

    @MainActor private static var window: NSWindow?

    /// Opened from the menu bar panel, the About window would sit under it (the panel floats above normal windows):
    /// it then takes the level just above the panel.
    @MainActor static func show() {
        let from = NSApp.keyWindow?.level ?? .normal
        let window = window ?? make()
        Self.window = window
        NSApp.activate()
        window.level = from > .normal ? NSWindow.Level(rawValue: from.rawValue + 1) : .normal
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor private static func make() -> NSWindow {
        let host = NSHostingController(rootView: AboutView())
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "À propos de Vibe Cleaner"
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            VStack(spacing: DS.Space.xs) {
                Text("Vibe Cleaner").font(.title2.bold())
                Text("Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: DS.Space.m) {
                Text("Outil gratuit et open source, créé par [GuigsEvt](\(AboutPanel.authorURL.absoluteString)) sur son temps libre, sans but lucratif.")
                Text("Il a été développé entièrement via des agents IA (« vibe codé »). Le code est public, chacun peut le lire, le vérifier et l'adapter.")
                Link("Code source sur GitHub", destination: AboutPanel.sourceURL).pointerStyle(.link)
                // The warning the README opens with: said where people look before trusting a cleaner.
                Label {
                    Text("App vibe codée, à utiliser à vos propres risques. Elle n'a fait l'objet d'aucun audit de sécurité. Gardez une sauvegarde à jour et commencez en mode simulation.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                .padding(DS.Space.s)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(Theme.warning.opacity(0.12)))
                Group {
                    Text("Fourni tel quel, sans garantie. L'auteur n'est responsable d'aucun dommage ni d'aucune perte de données liés à son utilisation.")
                    Text("Projet indépendant, sans lien avec Apple ni avec les éditeurs d'autres nettoyeurs.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if let copyright = info["NSHumanReadableCopyright"] as? String {
                Divider()
                Text(copyright).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.xl).padding(.top, DS.Space.xxl).padding(.bottom, DS.Space.xl)
        .frame(width: 360)
    }
}
