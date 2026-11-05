import SwiftUI
import VibeCleanerCore

/// Guide tab: the Mac, its health score and the sorted recommendations.
/// Holding Option while opening it (or Prefs.guideDebug) shows the factor simulation panel.
struct GuideView: View {
    let model: AppModel
    @State private var debug = false
    @State private var forced: Set<String> = []
    @AppStorage(Prefs.guideDebug) private var debugSetting = false

    var body: some View {
        let monitor = model.monitor
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                if let base = monitor.health {
                    let health = forced.isEmpty ? base : Guide.simulate(base, forcing: forced)
                    let visible = Guide.visible(health.issues, skipped: monitor.skipped)
                    GuideHero(health: health, mac: monitor.mac).entrance(0)
                    if !forced.isEmpty {
                        Label("Simulation : affichage seulement, rien n'est modifié sur le Mac.", systemImage: "testtube.2")
                            .font(.callout.weight(.medium)).foregroundStyle(Theme.warning)
                            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                            .glass(tint: Theme.warning, radius: DS.Radius.control)
                            .entrance(1)
                    }
                    recommendations(visible, hidden: health.issues.count - visible.count)
                } else {
                    VStack(spacing: DS.Space.m) {
                        ProgressView().controlSize(.large)
                        Text("Analyse de l'état du Mac…").foregroundStyle(.secondary)
                    }
                    .padding(DS.Space.xxl)
                    .glass(tint: Theme.accent("guide"), radius: DS.Radius.tile)
                    .padding(.top, 120)
                    .entrance(0)
                }
                if debug || debugSetting { debugPanel.entrance(8) }
            }
            .padding(.horizontal, DS.Space.xxl).padding(.vertical, DS.Space.xl)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            monitor.start()
            if NSEvent.modifierFlags.contains(.option) { debug = true }
        }
    }

    @ViewBuilder private func recommendations(_ list: [HealthIssue], hidden: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recommandations").font(.title3.bold())
                if !list.isEmpty {
                    Text("\(list.count)").font(.callout.bold().monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                        .accessibilityLabel("\(list.count) recommandation(s)")
                }
                Spacer()
                if hidden > 0 {
                    Button { model.monitor.clearSkips() } label: {
                        Label("Réafficher \(hidden) ignorée(s)", systemImage: "eye")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Réafficher \(hidden) recommandation(s) ignorée(s)")
                }
            }
            .entrance(1)
            if list.isEmpty {
                GuideAllGood().entrance(2)
            } else {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, issue in
                    RecommendationCard(issue: issue, simulated: forced.contains(issue.id), monitor: model.monitor) { model.show($0) }
                        .entrance(i + 2)
                }
            }
        }
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Label("Simulation des facteurs (développement)", systemImage: "ladybug").font(.headline)
            Text("Force l'affichage d'un facteur pour vérifier les textes et le score. Aucune action réelle.").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]) {
                ForEach(Guide.factorIDs, id: \.self) { id in
                    Toggle(id, isOn: Binding(get: { forced.contains(id) }, set: { if $0 { forced.insert(id) } else { forced.remove(id) } }))
                        .font(.caption.monospaced())
                }
            }
            HStack {
                Button("Tout effacer") { forced = [] }.buttonStyle(GlassButtonStyle())
                Spacer()
                Toggle("Toujours afficher ce panneau", isOn: $debugSetting).font(.caption)
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(tint: Theme.warning.opacity(0.6))
    }
}

/// Top of the Guide: the Mac glowing in the health colour, its model, the score ring and the status in words.
struct GuideHero: View {
    let health: HealthAssessment
    let mac: MacModel?
    @State private var scoreInfo = false

    private var color: Color { HealthHeader.color(health.status) }

    private var symbol: String {
        switch health.status {
        case .excellent, .good: "heart.fill"
        case .fair: "stethoscope"
        case .poor: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.xxl) {
                MacHero(tint: color, symbol: symbol, width: 200).padding(.vertical, DS.Space.l)
                summary(alignment: .leading)
            }
            .padding(.horizontal, DS.Space.xl)
            HStack(spacing: DS.Space.xl) {
                MacHero(tint: color, symbol: symbol, width: 150).padding(.vertical, DS.Space.s)
                summary(alignment: .leading)
            }
            .padding(.horizontal, DS.Space.l)
            VStack(spacing: DS.Space.xl) {
                MacHero(tint: color, symbol: symbol, width: 200)
                summary(alignment: .center)
            }
        }
        .padding(.vertical, DS.Space.l)
        .frame(maxWidth: .infinity)
        .glass(tint: color, radius: DS.Radius.tile)
    }

    private func summary(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: DS.Space.m) {
            if let mac {
                Label([mac.name, mac.chip].compactMap { $0 }.joined(separator: " · "), systemImage: mac.symbol)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            }
            HStack(spacing: DS.Space.l) {
                RingGauge(value: Double(health.score) / Double(HealthAssessment.maxScore), tint: color, lineWidth: 11) {
                    VStack(spacing: 0) {
                        Text("\(health.score)").font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        Text("sur 100").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 118, height: 118)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Score de santé : \(health.score) sur 100")
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Santé du Mac").font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: DS.Space.s) {
                        Text(health.status.title).font(.system(size: 26, weight: .bold)).foregroundStyle(color)
                        Button { scoreInfo.toggle() } label: { Image(systemName: "info.circle").font(.body) }
                            .buttonStyle(.borderless).pointerStyle(.link)
                            .help("Comment le score est calculé").accessibilityLabel("Comment le score est calculé")
                            .popover(isPresented: $scoreInfo) {
                                GuideInfoPopover(symbol: "heart.text.square", title: "Score de santé", text: Guide.scoreExplanation, tint: color)
                            }
                    }
                    Text(health.status.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 260, alignment: .leading)
                }
            }
        }
    }
}

/// Glass popover for « En savoir plus » and the score explanation.
struct GuideInfoPopover: View {
    let symbol: String
    let title: String
    let text: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .frame(width: 320, alignment: .leading)
        .background(LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// Empty list: the « tout va bien » state.
struct GuideAllGood: View {
    var body: some View {
        VStack(spacing: DS.Space.m) {
            ZStack {
                Circle().fill(Theme.healthy.opacity(0.18)).frame(width: 84, height: 84)
                Circle().strokeBorder(Theme.healthy.opacity(0.4), lineWidth: 1).frame(width: 84, height: 84)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(Theme.healthy.gradient)
            }
            .shadow(color: Theme.healthy.opacity(0.5), radius: 18)
            .accessibilityHidden(true)
            Text(Guide.emptyTitle).font(.title3.bold())
            Text(Guide.emptyDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.vertical, DS.Space.xxl).padding(.horizontal, DS.Space.xl)
        .frame(maxWidth: .infinity)
        .glass(tint: Theme.healthy, radius: DS.Radius.tile)
    }
}

struct RecommendationCard: View {
    let issue: HealthIssue
    let simulated: Bool
    let monitor: MonitorModel
    let open: (String) -> Void
    @State private var more = false
    @State private var skip = false

    var tint: Color {
        switch issue.severity {
        case .critical: Theme.critical
        case .warning: Theme.warning
        case .info: Theme.healthy
        }
    }

    private var symbol: String {
        switch issue.severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "lightbulb.fill"
        }
    }

    private var severityName: String {
        switch issue.severity {
        case .critical: "Critique"
        case .warning: "Important"
        case .info: "Conseil"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.l) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1)
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)
            .accessibilityLabel(severityName)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(issue.title).font(.headline)
                Text(issue.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s) {
                    Button { more.toggle() } label: { Label("En savoir plus…", systemImage: "info.circle") }
                        .buttonStyle(.borderless).pointerStyle(.link).foregroundStyle(tint == Theme.warning ? Theme.warningText : tint)
                        .font(.callout.weight(.medium))
                        .popover(isPresented: $more) {
                            GuideInfoPopover(symbol: symbol, title: issue.title, text: Guide.explanation(issue.id), tint: tint)
                        }
                    if issue.penalty > 0 {
                        Text("−\(issue.penalty) points").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                if let t = IssueAction.title(issue) {
                    Button(t) { IssueAction.perform(issue, monitor: monitor, open: open) }
                        .buttonStyle(GlassButtonStyle(tint: (issue.module.map(Theme.accent) ?? Theme.accent("guide")).deepened, prominent: true))
                        .disabled(simulated)
                }
                Button { skip.toggle() } label: { Label("Ignorer", systemImage: "chevron.down").labelStyle(TrailingIconLabel()) }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(simulated)
                    .accessibilityLabel("Ignorer « \(issue.title) »")
                    .popover(isPresented: $skip, arrowEdge: .bottom) { skipOptions }
            }
            .fixedSize()
        }
        .padding(DS.Space.l)
        .glass(tint: tint.opacity(0.75), interactive: true)
    }

    /// Same choices as `SkipMenu`, as a small glass list.
    private var skipOptions: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ignorer…").font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, DS.Space.s).padding(.bottom, 2)
            ForEach(SnoozeOption.allCases, id: \.self) { o in
                SkipOptionRow(title: o.title) {
                    skip = false
                    monitor.skip(issue.id, until: o.until(from: Date()))
                }
            }
        }
        .padding(DS.Space.s)
        .frame(width: 200)
    }
}

private struct SkipOptionRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.s).padding(.vertical, 5)
                .background(hovering ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}

/// Title then a small icon (menu-like chevron).
struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}

extension Color {
    /// The colour darkened by about 40 %: white text stays readable on light accents (sky blue, yellow, green).
    var deepened: Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return Color(nsColor: ns.blended(withFraction: 0.42, of: .black) ?? ns)
    }
}
