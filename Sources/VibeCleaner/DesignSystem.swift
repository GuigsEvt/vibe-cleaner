import Charts
import SwiftUI

/// Shared visual language: glass surfaces tinted by the module, a soft lift on hover, staggered entrances.
/// Every screen builds on these pieces instead of styling cards and buttons by hand.
enum DS {
    /// Spacing scale (pt). Nothing outside it.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Corner radii, from small controls to the large tiles.
    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 14
        static let tile: CGFloat = 20
    }

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.78)
}

// MARK: - Glass

/// Glass surface: system material, a wash of the accent colour, a light rim on the top edge and a soft shadow.
/// `interactive` surfaces lift slightly under the pointer (scale and shadow), like iOS cards.
struct GlassSurface: ViewModifier {
    var tint: Color?
    var radius: CGFloat
    var interactive: Bool
    var selected: Bool
    @State private var hovering = false
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let lifted = interactive && hovering
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint {
                        shape.fill(LinearGradient(colors: [tint.opacity(selected ? 0.32 : 0.2), tint.opacity(0.04)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    shape.fill(.white.opacity(lifted ? 0.05 : 0))
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(lifted || selected ? 0.38 : 0.22), .white.opacity(0.04)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(lifted ? 0.32 : 0.18), radius: lifted ? 18 : 8, y: lifted ? 10 : 4)
            .scaleEffect(lifted && !reduceMotion ? 1.025 : 1)
            .animation(DS.spring, value: lifted)
            .onHover { if interactive { hovering = $0 } }
    }
}

extension View {
    /// Glass card. Pass the module accent as `tint`; `interactive` for anything clickable.
    func glass(tint: Color? = nil, radius: CGFloat = DS.Radius.card, interactive: Bool = false, selected: Bool = false) -> some View {
        modifier(GlassSurface(tint: tint, radius: radius, interactive: interactive, selected: selected))
    }
}

/// Secondary action on glass: a capsule that brightens on hover and presses in.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, tint: tint, prominent: prominent).pointerStyle(.link)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color?
    let prominent: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, DS.Space.m).padding(.vertical, 6)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                // Darkened so white text stays readable on light accents (mint, yellow).
                Capsule().fill(prominent ? AnyShapeStyle((tint ?? .accentColor).mix(with: .black, by: 0.3).gradient) : AnyShapeStyle(.thinMaterial))
                Capsule().fill(.white.opacity(hovering ? 0.12 : 0))
            }
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0.25 : 0.16), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(DS.spring, value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }
}

/// Standard bordered buttons with the pointing-hand cursor. Set once on a window, sheet or panel root:
/// every button below that keeps the default style inherits it.
struct HandCursorButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderedButtonStyle().makeBody(configuration: configuration).pointerStyle(.link)
    }
}

extension View {
    /// Pointing-hand cursor for default buttons in this subtree.
    func handCursorButtons() -> some View { buttonStyle(HandCursorButtonStyle()) }
}

// MARK: - Entrance

/// Staggered entrance: the view slides up a little and fades in, `index` × 45 ms after it appears.
/// With reduced motion it only fades.
struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .scaleEffect(shown || reduceMotion ? 1 : 0.985)
            .onAppear {
                let delay = Double(min(index, 12)) * 0.045
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.86).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func entrance(_ index: Int = 0) -> some View { modifier(Entrance(index: index)) }
}

// MARK: - Gauges and charts

/// Circular gauge with a gradient arc; the centre shows `label`.
struct RingGauge<Label: View>: View {
    let value: Double
    var tint: Color
    var lineWidth: CGFloat = 8
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(0),
                                        endAngle: .degrees(360 * max(value, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Conic gradients are drawn on the CPU at each frame of the progress animation; Metal draws them instead.
                // The stroke overflows the frame by half its width; drawingGroup clips to the frame, so it gets room.
                .padding(lineWidth).drawingGroup().padding(-lineWidth)
                .shadow(color: tint.opacity(0.5), radius: 6)
            label()
        }
        .animation(.smooth(duration: 0.6), value: value)
    }
}

/// Smooth area + line chart without axes, for live readings (CPU, memory, battery, network).
struct Sparkline: View {
    let values: [Double]
    var tint: Color
    /// Fixed vertical domain (0...100 for percentages); nil adapts to the data.
    var domain: ClosedRange<Double>?

    var body: some View {
        let points = Array(values.enumerated())
        let chart = Chart(points, id: \.offset) { p in
            AreaMark(x: .value("t", p.offset), y: .value("v", p.element))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("t", p.offset), y: .value("v", p.element))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        Group {
            if let domain { chart.chartYScale(domain: domain) } else { chart }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Mac illustration

/// A MacBook drawn in SwiftUI: the screen glows with the module colour and shows its symbol. Static on purpose:
/// an endless float kept the window redrawing at the display rate.
struct MacHero: View {
    var tint: Color
    var symbol: String
    var width: CGFloat = 300

    var body: some View {
        let screenH = width * 0.64
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: width * 0.045, style: .continuous)
                    .fill(Color(white: 0.09))
                RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.45), Color(red: 0.08, green: 0.07, blue: 0.14)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RadialGradient(colors: [.white.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: width * 0.6)
                            .clipShape(RoundedRectangle(cornerRadius: width * 0.03, style: .continuous))
                    )
                    .padding(width * 0.028)
                Image(systemName: symbol)
                    .font(.system(size: width * 0.17, weight: .light))
                    .foregroundStyle(.white)
                    .shadow(color: tint, radius: 18)
                Capsule().fill(Color(white: 0.02)).frame(width: width * 0.12, height: width * 0.018)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, width * 0.028)
            }
            .frame(width: width, height: screenH)
            .overlay(RoundedRectangle(cornerRadius: width * 0.045, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            // Base: a thin aluminium slab with the opening notch.
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: width * 0.03, bottomTrailingRadius: width * 0.03, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.42)], startPoint: .top, endPoint: .bottom))
                UnevenRoundedRectangle(bottomLeadingRadius: width * 0.012, bottomTrailingRadius: width * 0.012)
                    .fill(Color(white: 0.3)).frame(width: width * 0.16, height: width * 0.012)
            }
            .frame(width: width * 1.16, height: width * 0.045)
        }
        .shadow(color: tint.opacity(0.45), radius: 40, y: 18)
        .background(alignment: .bottom) {
            Ellipse().fill(.black.opacity(0.45)).frame(width: width * 1.1, height: width * 0.08).blur(radius: 14).offset(y: width * 0.07)
        }
        .accessibilityHidden(true)
    }
}
