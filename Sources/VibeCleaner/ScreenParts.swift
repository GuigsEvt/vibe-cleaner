import SwiftUI

/// Small building blocks of the main window screens (intro, progress, tiles, summary, sheets), on top of `DesignSystem`.

/// What each module looks at, shown as glass chips under the intro title.
enum IntroChips {
    struct Chip: Hashable {
        let symbol: String
        let title: String
        /// Module whose colour tints the chip (Vibe Check shows one chip per aggregated module).
        var moduleID: String? = nil
    }

    static func chips(for entry: ModuleEntry) -> [Chip] {
        switch entry.id {
        case "vibecheck": entry.modules.map { Chip(symbol: $0.symbol, title: $0.title, moduleID: $0.id) }
        case "junk": [Chip(symbol: "archivebox", title: "Caches des apps"), Chip(symbol: "doc.text", title: "Journaux"),
                      Chip(symbol: "paperclip", title: "Pièces jointes"), Chip(symbol: "trash", title: "Corbeilles")]
        case "protection": [Chip(symbol: "power", title: "Lancement au démarrage"), Chip(symbol: "checkmark.seal", title: "Signatures des apps"),
                            Chip(symbol: "shield.lefthalf.filled", title: "Règles XProtect")]
        case "performance": [Chip(symbol: "wrench.and.screwdriver", title: "Tâches de maintenance"),
                             Chip(symbol: "person.crop.circle.badge.checkmark", title: "Éléments de connexion"),
                             Chip(symbol: "gearshape.2", title: "Agents de lancement")]
        case "applications": [Chip(symbol: "xmark.app", title: "Désinstallation complète"), Chip(symbol: "shippingbox", title: "Restes d'apps"),
                              Chip(symbol: "arrow.down.app", title: "Mises à jour macOS")]
        case "clutter": [Chip(symbol: "doc.on.doc", title: "Doublons"), Chip(symbol: "photo.on.rectangle", title: "Images similaires"),
                         Chip(symbol: "externaldrive", title: "Gros fichiers"), Chip(symbol: "arrow.down.circle", title: "Téléchargements")]
        case "cloud": [Chip(symbol: "icloud", title: "iCloud Drive"), Chip(symbol: "externaldrive.connected.to.line.below", title: "Dropbox"),
                       Chip(symbol: "folder", title: "Google Drive"), Chip(symbol: "folder.badge.person.crop", title: "OneDrive")]
        default: []
        }
    }
}

/// A glass chip: symbol tinted by its module, short label.
struct GlassChip: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).imageScale(.medium)
            Text(title).lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, DS.Space.m).padding(.vertical, 7)
        .glass(tint: tint, radius: 16)
        .accessibilityElement(children: .combine)
    }
}

/// Chips on one line when they fit, otherwise on two centred lines.
struct ChipRow: View {
    let chips: [IntroChips.Chip]
    let tint: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(chips)
            VStack(spacing: DS.Space.s) {
                line(Array(chips.prefix((chips.count + 1) / 2)))
                line(Array(chips.dropFirst((chips.count + 1) / 2)))
            }
        }
    }

    private func line(_ list: [IntroChips.Chip]) -> some View {
        HStack(spacing: DS.Space.s) {
            ForEach(Array(list.enumerated()), id: \.element) { _, c in
                GlassChip(symbol: c.symbol, title: c.title, tint: c.moduleID.map(Theme.accent) ?? tint)
            }
        }
        .fixedSize()
    }
}

/// Symbol in a circle filled with the accent, like the icons of System Settings.
struct TintedIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                Circle().fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: tint.opacity(0.45), radius: size * 0.18, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

/// Large symbol in a glowing glass disc (summary, empty states); pops in once when it appears.
struct GlowSymbol: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 116
    @State private var shown = false
    @ReducedMotion private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.5), .clear], center: .center, startRadius: size * 0.2, endRadius: size * 0.95))
                .frame(width: size * 1.9, height: size * 1.9)
            Circle().fill(.ultraThinMaterial).frame(width: size, height: size)
            Circle().fill(LinearGradient(colors: [tint.opacity(0.8), tint.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), tint.opacity(0.2)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: tint, radius: 12)
                .symbolEffect(.bounce, value: shown)
        }
        .frame(width: size, height: size)
        .scaleEffect(shown || reduceMotion ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.62)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}

/// Arc spinning around the ring when the progress is unknown; a plain spinner with reduced motion.
struct IndeterminateRing: View {
    let tint: Color
    var lineWidth: CGFloat = 12
    @State private var spin = false
    @ReducedMotion private var reduceMotion

    var body: some View {
        if reduceMotion {
            ProgressView().controlSize(.large)
        } else {
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(AngularGradient(colors: [tint.opacity(0), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(100)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // The stroke overflows the frame by half its width; drawingGroup clips to the frame, so it gets room.
                .padding(lineWidth).drawingGroup().padding(-lineWidth)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true } }
        }
    }
}

/// Sheet background: the dark canvas with a faint wash of the module colour.
struct SheetBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.08, blue: 0.13)
            RadialGradient(colors: [tint.opacity(0.28), .clear], center: .topLeading, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// Header of a sheet: tinted icon, title and an explanation.
struct SheetHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            TintedIcon(symbol: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
