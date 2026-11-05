import AppKit
import SwiftUI
import VibeCleanerCore

/// Menu bar icon: the app's drop, with a notification badge when something needs doing:
/// "!" for a critical issue, the count of recommendations otherwise. Drawn as a template, so state is shape, not colour.
struct MenuBarLabel: View {
    let monitor: MonitorModel

    var body: some View {
        let badge = Guide.badge(monitor.recommendations)
        Image(nsImage: MenuBarIcon.image(badge: badge.map { $0.severity == .critical ? "!" : $0.count > 9 ? "9+" : "\($0.count)" }))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.map { "Vibe Cleaner, " + ($0.severity == .critical ? "problème critique" : "\($0.count) recommandation(s)") } ?? "Vibe Cleaner")
            .onAppear { monitor.start() }
    }
}

/// Template image for the status item: the drop with its wave cut out, and a round badge holding `badge`
/// at its upper right, beside the tip, separated from the drop by a thin gap.
enum MenuBarIcon {
    static func image(badge: String?) -> NSImage {
        let height: CGFloat = 18
        let width: CGFloat = badge == nil ? 14 : (badge!.count > 1 ? 23 : 20)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // Drop: 12 wide, 16 tall, point at the top.
            let drop = NSBezierPath()
            let r: CGFloat = 6, cx: CGFloat = 7, cy: CGFloat = 1 + r
            drop.move(to: NSPoint(x: cx, y: 17))
            drop.curve(to: NSPoint(x: cx + r, y: cy), controlPoint1: NSPoint(x: cx + 1.6, y: 14), controlPoint2: NSPoint(x: cx + r, y: cy + 3.6))
            drop.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: 180, clockwise: true)
            drop.curve(to: NSPoint(x: cx, y: 17), controlPoint1: NSPoint(x: cx - r, y: cy + 3.6), controlPoint2: NSPoint(x: cx - 1.6, y: 14))
            drop.close()
            NSColor.black.setFill()
            drop.fill()
            // The wave, cut out of the drop.
            cg.setBlendMode(.clear)
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: cx - 3.6, y: cy))
            wave.curve(to: NSPoint(x: cx, y: cy), controlPoint1: NSPoint(x: cx - 2.4, y: cy + 1.6), controlPoint2: NSPoint(x: cx - 1.2, y: cy + 1.6))
            wave.curve(to: NSPoint(x: cx + 3.6, y: cy), controlPoint1: NSPoint(x: cx + 1.2, y: cy - 1.6), controlPoint2: NSPoint(x: cx + 2.4, y: cy - 1.6))
            wave.lineWidth = 1.6
            wave.lineCapStyle = .round
            wave.stroke()
            guard let badge else { cg.setBlendMode(.normal); return true }
            // Badge: a gap ring cleared around it, the disc, then the text cut out of the disc.
            let bw: CGFloat = badge.count > 1 ? 13 : 10, bh: CGFloat = 10
            let rect = NSRect(x: width - bw, y: height - bh, width: bw, height: bh)
            NSBezierPath(roundedRect: rect.insetBy(dx: -1.4, dy: -1.4), xRadius: bh / 2 + 1.4, yRadius: bh / 2 + 1.4).fill()
            cg.setBlendMode(.normal)
            NSBezierPath(roundedRect: rect, xRadius: bh / 2, yRadius: bh / 2).fill()
            cg.setBlendMode(.destinationOut)
            let text = NSAttributedString(string: badge, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .heavy), .foregroundColor: NSColor.black])
            let ts = text.size()
            text.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2 + 0.3))
            cg.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        return image
    }
}
