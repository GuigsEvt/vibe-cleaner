import SwiftUI
import VibeCleanerCore

/// Greedy circle packing: largest bubble in the centre, others placed on a spiral without overlap.
struct BubbleChart: View {
    let bubbles: [SpaceBubble]
    /// Paths ticked in the list, outlined on the map.
    let selected: Set<String>
    @Binding var hovered: String?
    let tooltip: (SpaceBubble) -> String
    let open: (SpaceBubble) -> Void
    /// Double click on the background: parent level.
    let up: () -> Void
    let menu: (SpaceNode) -> AnyView

    /// Empty space kept between two bubbles.
    private static let gap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let placed = layout(in: geo.size)
            ZStack {
                Color.clear.contentShape(Rectangle()).onTapGesture(count: 2, perform: up)
                if placed.isEmpty {
                    VStack(spacing: DS.Space.s) {
                        Image(systemName: "circle.dashed").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                        Text("Trop vide pour être visualisé").font(.headline).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(placed.enumerated()), id: \.element.0.id) { index, item in
                    let (b, center, r) = item
                    let id = b.node?.path ?? b.id
                    let selection = b.node?.selection(in: selected)
                    let isSelected = (selection?.bytes ?? 0) > 0
                    SpaceBubbleView(bubble: b, radius: r, index: index, selected: isSelected, entire: selection?.entire ?? false, hovered: hovered == id)
                        .frame(width: r * 2, height: r * 2)
                        .contentShape(Circle())
                        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
                        .onTapGesture { open(b) }
                        .pointerStyle(.link)
                        .help(tooltip(b))
                        .contextMenu { if let n = b.node { menu(n) } }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(b.name), \(FileSizer.format(b.size))" + (isSelected ? (selection?.entire == true ? ", sélectionné" : ", partiellement sélectionné") : ""))
                        .accessibilityHint(tooltip(b))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { open(b) }
                        .zIndex(hovered == id ? 1 : 0)
                        .position(center)
                }
            }
            .animation(.spring(duration: 0.4), value: bubbles.map(\.id))
        }
    }

    /// Shrinks the whole map until every bubble fits inside the frame.
    private func layout(in size: CGSize) -> [(SpaceBubble, CGPoint, CGFloat)] {
        let count = bubbles.filter { $0.size > 0 }.count
        var scale: CGFloat = 1
        var placed = place(in: size, scale: scale)
        for _ in 0..<8 where placed.count < count {
            scale *= 0.85
            placed = place(in: size, scale: scale)
        }
        return placed
    }

    private func place(in size: CGSize, scale: CGFloat) -> [(SpaceBubble, CGPoint, CGFloat)] {
        let items = bubbles.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard !items.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let gap = Self.gap
        let total = Double(items.reduce(0) { $0 + $1.size })
        let area = Double(size.width * size.height) * 0.55
        var radii = items.map { CGFloat(sqrt(Double($0.size) / total * area / .pi)) * scale }
        let maxR = min(size.width, size.height) * 0.42 * scale
        if let first = radii.first, first > maxR { radii = radii.map { $0 * maxR / first } }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // A small margin so a hovered bubble can grow without touching the edge.
        func inside(_ p: CGPoint, _ r: CGFloat) -> Bool {
            p.x - r >= gap && p.x + r <= size.width - gap && p.y - r >= gap && p.y + r <= size.height - gap
        }
        var placed: [(SpaceBubble, CGPoint, CGFloat)] = []
        for (b, r) in zip(items, radii) {
            var pos = c
            if !placed.isEmpty {
                var found = false
                var dist = placed[0].2 + r + gap
                while !found && dist < max(size.width, size.height) {
                    for step in 0..<72 {
                        let a = Double(step) * .pi / 36
                        let p = CGPoint(x: c.x + dist * cos(a), y: c.y + dist * sin(a) * 0.8)
                        if inside(p, r), placed.allSatisfy({ hypot($0.1.x - p.x, $0.1.y - p.y) >= $0.2 + r + gap }) { pos = p; found = true; break }
                    }
                    dist += 4
                }
                if !found { continue }
            }
            placed.append((b, pos, r))
        }
        return placed
    }
}

/// One bubble: a glassy sphere in the Radar colour (hue shifted a little per rank), lit from the top left.
/// Folded items are a dashed outline, purgeable space a neutral grey; the pointer zooms the bubble slightly.
struct SpaceBubbleView: View {
    let bubble: SpaceBubble
    let radius: CGFloat
    let index: Int
    let selected: Bool
    /// The whole bubble is ticked (itself or an ancestor), not only some of its content.
    var entire = true
    let hovered: Bool
    @ReducedMotion private var reduceMotion

    private var isPurgeable: Bool { bubble.id == purgeableBubble(0).id }
    private var base: Color { isPurgeable ? Color(white: 0.75) : Theme.accent("radar") }
    /// Neighbours differ a little: −24°…+24° around the accent.
    private var hue: Angle { .degrees(isPurgeable ? 0 : Double(index % 5) * 12 - 24) }

    var body: some View {
        let r = radius
        ZStack {
            if bubble.isAggregate {
                Circle().fill(base.opacity(hovered ? 0.16 : 0.08))
                Circle().strokeBorder(base.opacity(hovered ? 0.7 : 0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else {
                Circle()
                    .fill(RadialGradient(colors: [base.opacity(hovered ? 0.95 : 0.8), base.opacity(0.42), base.opacity(0.2)],
                                         center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: r * 1.5))
                    .hueRotation(hue)
                // Specular highlight: the glass look.
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: r * 1.1, height: r * 0.6)
                    .offset(y: -r * 0.48)
                    .blendMode(.plusLighter)
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 1)
            }
            if selected {
                Circle().strokeBorder(Theme.warning, style: entire ? StrokeStyle(lineWidth: 3) : StrokeStyle(lineWidth: 2, dash: [6, 4]))
                if entire, r > 22 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: min(22, max(14, r / 5))))
                        .foregroundStyle(.black, Theme.warning)
                        .offset(x: r * 0.62, y: -r * 0.62)
                }
            }
            label(r)
        }
        .shadow(color: (bubble.isAggregate ? .clear : base).opacity(hovered ? 0.55 : 0.18), radius: hovered ? 16 : 6)
        .scaleEffect(hovered && !reduceMotion ? 1.06 : 1)
        .animation(DS.spring, value: hovered)
    }

    @ViewBuilder private func label(_ r: CGFloat) -> some View {
        if r > 28 {
            VStack(spacing: 2) {
                if r > 70 {
                    Image(systemName: symbol).font(.system(size: min(26, r / 4.5), weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 2)
                }
                Text(bubble.name).font(.system(size: max(10, min(16, r / 4.6)), weight: .semibold))
                    .lineLimit(r > 44 ? 2 : 1).multilineTextAlignment(.center).minimumScaleFactor(0.75)
                Text(FileSizer.format(bubble.size)).font(.system(size: max(9, min(13, r / 5.8)), weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .padding(6).frame(width: r * 1.6)
        } else if r > 14 {
            // Small bubble: the name alone, shrunk to fit; the size is in the tooltip.
            Text(bubble.name).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.white).shadow(color: .black.opacity(0.45), radius: 1.5)
                .frame(width: r * 1.7)
        }
    }

    private var symbol: String {
        if isPurgeable { return "arrow.3.trianglepath" }
        guard let n = bubble.node else { return "ellipsis" }
        if n.isPackage { return n.name.hasSuffix(".app") ? "app.dashed" : "shippingbox.fill" }
        return n.isDirectory ? "folder.fill" : "doc.fill"
    }
}
