import SwiftUI
import VibeCleanerCore

/// Volume bar of Radar: used, selected, purgeable, free.
struct RadarGauge: View {
    let gauge: VolumeGauge

    private var segments: [(String, Int64, Color)] {
        [("Utilisé", gauge.used, Theme.accent("radar")), ("Sélectionné", gauge.selected, Theme.warning),
         ("Purgeable", gauge.purgeable, .white.opacity(0.5)), ("Libre", gauge.free, .white.opacity(0.1))]
    }

    private var usedPercent: Int {
        guard gauge.total > 0 else { return 0 }
        return Int((Double(gauge.total - gauge.free) / Double(gauge.total) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text("\(FileSizer.format(gauge.total - gauge.free)) utilisés sur \(FileSizer.format(gauge.total))")
                    .font(.callout.weight(.semibold).monospacedDigit()).lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Text("\(usedPercent) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments, id: \.0) { name, bytes, color in
                        if bytes > 0 {
                            Capsule().fill(color.gradient)
                                .frame(width: max(3, geo.size.width * CGFloat(Double(bytes) / Double(max(1, gauge.total)))))
                                .help("\(name) : \(FileSizer.format(bytes)) sur \(FileSizer.format(gauge.total))")
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .animation(DS.spring, value: gauge)
            }
            .frame(height: 10)
            .background(Capsule().fill(.white.opacity(0.06)))
            .clipShape(Capsule())
            .shadow(color: Theme.accent("radar").opacity(0.35), radius: 4)
            // Names and sizes when they fit, names only otherwise (never wrapped mid-word).
            ViewThatFits(in: .horizontal) {
                legend(sizes: true)
                legend(sizes: false)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disque : " + segments.filter { $0.1 > 0 }.map { "\($0.0) \(FileSizer.format($0.1))" }.joined(separator: ", "))
    }

    private func legend(sizes: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(segments, id: \.0) { name, bytes, color in
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                    Text(sizes ? "\(name) \(FileSizer.format(bytes))" : name).lineLimit(1).fixedSize()
                }
                .help("\(name) : \(FileSizer.format(bytes))")
            }
        }
    }
}
