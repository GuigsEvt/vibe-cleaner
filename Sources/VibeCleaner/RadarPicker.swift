import SwiftUI
import VibeCleanerCore

/// First Radar screen: the volumes as glass cards with their gauge, then the other places to map.
struct RadarPicker: View {
    let model: RadarModel
    /// Injected by the render bench; the real screen lists the mounted volumes.
    var volumes: [VolumeInfo] = SpaceScanner.volumes()

    private let accent = RadarView.accent

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                header.entrance(0)
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    sectionTitle("Disques")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: DS.Space.l)], spacing: DS.Space.l) {
                        ForEach(Array(volumes.enumerated()), id: \.element.id) { i, v in
                            VolumeCard(volume: v) { model.scan(v.url, purgeable: v.purgeableCapacity) }.entrance(i + 1)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    sectionTitle("Autres emplacements")
                    HStack(spacing: DS.Space.l) {
                        PlaceCard(title: "Dossier personnel", detail: "Votre dossier utilisateur", symbol: "house.fill") {
                            model.scan(URL(fileURLWithPath: NSHomeDirectory()))
                        }
                        PlaceCard(title: "Stockage cloud", detail: "Fichiers présents sur ce Mac", symbol: "icloud.fill") { model.scanCloud() }
                            .help("iCloud Drive et ~/Library/CloudStorage (Google Drive, OneDrive, Dropbox…). Seuls les fichiers présents sur ce Mac comptent ; rien n'est téléchargé.")
                        PlaceCard(title: "Choisir un dossier…", detail: "N'importe quel dossier", symbol: "folder.badge.plus") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { model.scan(u) }
                        }
                    }
                }
                .entrance(volumes.count + 1)
                if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.critical)
                        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                        .glass(tint: Theme.critical, radius: DS.Radius.control)
                }
            }
            .padding(.horizontal, DS.Space.xxl).padding(.vertical, DS.Space.xl)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(RadialGradient(colors: [accent.opacity(0.85), accent.opacity(0.25)], center: UnitPoint(x: 0.3, y: 0.3),
                                             startRadius: 0, endRadius: 50))
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .frame(width: [74, 46, 34][i], height: [74, 46, 34][i])
                        .offset(x: [-14, 40, 26][i], y: [6, -20, 30][i])
                        .hueRotation(.degrees(Double(i) * 12 - 12))
                }
            }
            .frame(width: 130, height: 100)
            .shadow(color: accent.opacity(0.6), radius: 26)
            .accessibilityHidden(true)
            Text("Radar").font(.system(size: 32, weight: .bold))
            Text("Visualisez ce qui occupe votre disque, dossier par dossier, et faites le tri.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, DS.Space.s)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.headline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A volume: disk icon, name, ring of the used share and the free space.
struct VolumeCard: View {
    let volume: VolumeInfo
    let action: () -> Void

    private var accent: Color { RadarView.accent }
    private var usedFraction: Double {
        guard volume.totalCapacity > 0 else { return 0 }
        return Double(volume.totalCapacity - volume.availableCapacity) / Double(volume.totalCapacity)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                RingGauge(value: usedFraction, tint: usedFraction > 0.9 ? Theme.warning : accent, lineWidth: 7) {
                    Image(systemName: volume.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                        .font(.system(size: 18)).foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.name).font(.headline).lineLimit(1)
                    Text("\(FileSizer.format(volume.totalCapacity - volume.availableCapacity)) utilisés sur \(FileSizer.format(volume.totalCapacity))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    Text("\(FileSizer.format(volume.availableCapacity)) libres · \(Int((usedFraction * 100).rounded())) %")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity)
            .glass(tint: accent, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityLabel("Analyser \(volume.name), \(FileSizer.format(volume.totalCapacity - volume.availableCapacity)) utilisés sur \(FileSizer.format(volume.totalCapacity))")
    }
}

/// Folder, cloud or custom location.
struct PlaceCard: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(RadarView.accent)
                    .frame(width: 38, height: 38)
                    .background(RadarView.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(tint: RadarView.accent.opacity(0.6), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
