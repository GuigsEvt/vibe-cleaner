import SwiftUI

/// Colours per module: a dark canvas tinted by the active module.
enum Theme {
    static func accent(_ moduleID: String) -> Color {
        switch moduleID {
        case "vibecheck": Color(red: 0.62, green: 0.42, blue: 1.0)
        case "junk": Color(red: 0.25, green: 0.85, blue: 0.55)
        case "protection": Color(red: 1.0, green: 0.36, blue: 0.48)
        case "performance": Color(red: 1.0, green: 0.72, blue: 0.25)
        case "applications": Color(red: 0.30, green: 0.62, blue: 1.0)
        case "clutter": Color(red: 0.20, green: 0.82, blue: 0.80)
        case "radar": Color(red: 0.45, green: 0.80, blue: 1.0)
        case "cloud": Color(red: 0.55, green: 0.70, blue: 1.0)
        default: Color(red: 0.55, green: 0.55, blue: 0.95)
        }
    }

    static let healthy = Color(red: 0.30, green: 0.87, blue: 0.99)
    static let warning = Color(red: 1.0, green: 0.88, blue: 0.25)
    /// `warning` as text: the bright yellow is unreadable on a light background (menu bar panel, popovers).
    static let warningText = Color(nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 1.0, green: 0.88, blue: 0.25, alpha: 1)
                                                           : NSColor(red: 0.62, green: 0.44, blue: 0, alpha: 1)
    })
    static let critical = Color(red: 1.0, green: 0.32, blue: 0.32)
}

/// Settings › Général › Réduire les animations; `system` follows Accessibility.
enum MotionPreference: String {
    case system, enabled, disabled
}

/// True when animations should be reduced, from the setting and the system Accessibility option.
@propertyWrapper
struct ReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @AppStorage(Prefs.reduceMotion) private var preference = MotionPreference.system.rawValue

    var wrappedValue: Bool {
        switch MotionPreference(rawValue: preference) ?? .system {
        case .system: system
        case .enabled: true
        case .disabled: false
        }
    }
}

/// Dark canvas tinted by the active module: the tint cross-fades on change. It does not drift: any endless animation
/// keeps the whole glass window redrawing at the display rate (12 to 28 % CPU measured).
struct CanvasBackground: View {
    let moduleID: String
    @ReducedMotion private var reduceMotion

    var body: some View {
        let a = Theme.accent(moduleID)
        ZStack {
            Color(red: 0.07, green: 0.06, blue: 0.11)
            RadialGradient(colors: [a.opacity(0.45), .clear], center: .topTrailing,
                           startRadius: 20, endRadius: 700)
            RadialGradient(colors: [a.opacity(0.25), .clear], center: .bottomLeading,
                           startRadius: 10, endRadius: 600)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.8), value: moduleID)
    }
}

/// Large round main action button, bottom centre, on every screen:
/// a glass disc washed with the module colour, a light ring that turns under the pointer, a lift on hover and a press-in.
struct ActionButton: View {
    let title: String
    let moduleID: String
    var enabled = true
    /// Why the button is greyed out, shown under the pointer.
    var disabledHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(RoundActionStyle(tint: Theme.accent(moduleID)))
            .disabled(!enabled)
            .keyboardShortcut(.return, modifiers: .command)
            .disabledHint(enabled ? nil : disabledHint)
    }
}

private struct RoundActionStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        RoundActionBody(configuration: configuration, tint: tint).pointerStyle(.link)
    }
}

private struct RoundActionBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    static let size: CGFloat = 108
    @Environment(\.isEnabled) private var enabled
    @ReducedMotion private var reduceMotion
    @State private var hovering = false
    @State private var spin = false

    var body: some View {
        let size = Self.size
        let lit = hovering && enabled
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.3)], startPoint: .top, endPoint: .bottom))
            // Glassy highlight on the upper half.
            Ellipse().fill(LinearGradient(colors: [.white.opacity(lit ? 0.3 : 0.2), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.72, height: size * 0.42)
                .offset(y: -size * 0.22)
                .blur(radius: 2)
            // Light ring of the accent: turns while the pointer is on the button (never endlessly, see CanvasBackground).
            Circle()
                .strokeBorder(AngularGradient(colors: [tint, .white.opacity(0.95), tint.opacity(0.35), tint], center: .center), lineWidth: 3)
                .drawingGroup()
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1).padding(5)
            configuration.label
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, DS.Space.m)
        }
        .frame(width: size, height: size)
        .background {
            Circle().fill(RadialGradient(colors: [tint.opacity(lit ? 0.6 : 0.4), .clear], center: .center,
                                         startRadius: size * 0.35, endRadius: size * 0.95))
                .frame(width: size * 1.9, height: size * 1.9)
                .allowsHitTesting(false)
        }
        .contentShape(Circle())
        .shadow(color: .black.opacity(0.35), radius: lit ? 16 : 10, y: lit ? 8 : 5)
        .scaleEffect(configuration.isPressed ? 0.94 : (lit && !reduceMotion ? 1.05 : 1))
        .opacity(enabled ? 1 : 0.45)
        .animation(DS.spring, value: configuration.isPressed)
        .animation(DS.spring, value: lit)
        .onHover { hovering = $0 }
        .onChange(of: lit) { updateSpin(lit) }
    }

    private func updateSpin(_ lit: Bool) {
        if reduceMotion || !lit {
            withAnimation(.easeOut(duration: 0.3)) { spin = false }
        } else if !spin {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// Tooltip on a disabled control: AppKit shows none on the control itself, so it goes on a wrapper.
private struct DisabledHint: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text { content.padding(1).contentShape(Rectangle()).help(text) } else { content }
    }
}

extension View {
    func disabledHint(_ text: String?) -> some View { modifier(DisabledHint(text: text)) }
}

/// "1 élément", "6 éléments", "aucun élément".
func countLabel(_ n: Int, _ singular: String, _ plural: String) -> String {
    n == 0 ? "aucun \(singular)" : "\(n) \(n == 1 ? singular : plural)"
}

/// Hint for an action that needs a selection first: "Cochez une carte ou ouvrez-la avec « Revoir » pour choisir quoi protéger."
func selectFirstHint(_ actionTitle: String) -> String {
    "Rien n'est sélectionné : cochez une carte, ou ouvrez-la avec « Revoir », pour choisir quoi \(actionTitle.lowercased())."
}
