import SwiftUI
import VibeCleanerCore

/// Colours of the menu widgets: each one borrows the accent of the module it relates to.
enum MenuTint {
    static let storage = Theme.accent("clutter")
    static let memory = Theme.accent("vibecheck")
    static let cpu = Theme.accent("performance")
    static let cpuSystem = Theme.accent("applications")
    static let battery = Theme.accent("junk")
    static let network = Theme.accent("applications")
    static let upload = Theme.accent("junk")
    static let protection = Theme.accent("protection")
    static let devices = Theme.accent("cloud")
    static let disks = Theme.accent("radar")
    static let brand = Theme.accent("vibecheck")

    /// Categories of the storage and memory bars, in order.
    static let palette: [Color] = [Theme.accent("applications"), Theme.accent("vibecheck"), Theme.accent("performance"),
                                   Theme.accent("clutter"), Theme.accent("protection"), Theme.accent("junk"), Theme.accent("cloud")]

    /// Uncategorised remainder of a bar.
    static let other = Color.gray

    /// French formatting regardless of the system language (the app is French-only).
    static let locale = Locale(identifier: "fr_FR")
    static func relative(_ date: Date) -> String {
        date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale))
    }

    /// `base` while there is room, then warning and critical as a gauge fills up.
    static func level(_ fraction: Double, base: Color) -> Color {
        fraction > 0.9 ? Theme.critical : fraction > 0.8 ? Theme.warning : base
    }
}

/// App-icon-like square: white glyph on the tint's gradient.
struct TileIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    /// White glyph, except on the bright yellow where it would vanish.
    private var glyph: Color { tint == Theme.warning ? .black.opacity(0.72) : .white }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(glyph))
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

/// Rounded progress bar on a faint track that stays visible in light and dark appearance.
struct CapsuleBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.1))
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, g.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: height)
            .animation(.smooth(duration: 0.5), value: fraction)
            .accessibilityHidden(true)
    }
}

/// One coloured part of a `SegmentedBar`.
struct BarSegment: Identifiable {
    let title: String
    let value: Double
    let color: Color
    var id: String { title }
}

/// Horizontal bar split into coloured parts over `total`; what is left shows as the track.
struct SegmentedBar: View {
    let segments: [BarSegment]
    let total: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            let visible = segments.filter { $0.value > 0 }
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { s in
                    Rectangle().fill(s.color.gradient)
                        .frame(width: max(2, (g.size.width - gaps) * min(s.value / max(total, 1), 1)))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.1))
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Legend entry: dot, name and value.
struct LegendRow: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Small coloured state label ("En charge", "Normale"…).
struct StatusPill: View {
    let title: String
    let tint: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) } else { Circle().fill(tint).frame(width: 6, height: 6) }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.18)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
    }
}

/// Label and value on one line, in the detail sheets.
struct Line: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            Text(value).monospacedDigit().fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Big figure with its caption, for the metric squares of the detail sheets.
struct MetricTile: View {
    let title: String
    let value: String
    var note: String?
    /// Colours the note (a state worth noticing).
    var tint: Color?
    /// Glass tint of the square, usually the sheet's colour.
    var wash: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let note { Text(note).font(.caption2.weight(.medium)).foregroundStyle(tint == Theme.warning ? Theme.warningText : tint ?? .secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DS.Space.m)
        .glass(tint: tint ?? wash, radius: DS.Radius.control + 4)
        .accessibilityElement(children: .combine)
    }
}

/// Section of a detail sheet: optional caption, then content, on glass.
struct DetailCard<Content: View>: View {
    var title: String?
    var tint: Color?
    var index = 1
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.m)
        .glass(tint: tint)
        .entrance(index)
    }
}

/// Detail sheet shown from a widget: tinted header, then glass sections that slide in one after the other.
struct DetailPanel<Content: View>: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let tint: Color
    var width: CGFloat = 330
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                TileIcon(symbol: symbol, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title3.bold())
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .entrance(0)
            content()
        }
        .padding(DS.Space.l)
        .frame(width: width)
        .background {
            LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.03), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .handCursorButtons()
    }
}

/// Recent readings as layered area charts sharing one scale, over three faint guide lines.
/// Layers are drawn in order, so a stacked look comes from passing the total first.
struct HistoryChart: View {
    struct Series: Identifiable {
        let title: String
        let values: [Double]
        let color: Color
        var id: String { title }
    }

    let series: [Series]
    /// Fixed scale; nil fits the largest reading (with some headroom).
    var domain: ClosedRange<Double>?
    var format: (Double) -> String = { "\(Int($0)) %" }
    /// Prints the top of the scale above the chart (useful when it adapts to the data).
    var showsScale = false
    var height: CGFloat = 80

    private var scale: ClosedRange<Double> {
        if let domain { return domain }
        let top = series.flatMap(\.values).max() ?? 0
        return 0...max(top * 1.2, 1)
    }

    private var ready: Bool { series.contains { $0.values.count >= 2 } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<3) { i in
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                    if i < 2 { Spacer(minLength: 0) }
                }
            }
            if ready {
                ForEach(series) { s in Sparkline(values: s.values, tint: s.color, domain: scale) }
            } else {
                Label("Le graphe se remplit au fil des mesures…", systemImage: "chart.xyaxis.line")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
        .overlay(alignment: .topTrailing) {
            if showsScale, ready {
                Text(format(scale.upperBound)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    .padding(.horizontal, 4).background(Capsule().fill(.background.opacity(0.6)))
                    .offset(y: -7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map { "\($0.title) : \($0.values.last.map(format) ?? "aucune mesure")" }.joined(separator: ", "))
    }
}

/// `RingGauge` over a track that stays visible on a light background (the shared gauge's track is white).
struct MenuRing<Label: View>: View {
    let value: Double
    let tint: Color
    var lineWidth: CGFloat = 6
    @ViewBuilder var label: () -> Label

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            RingGauge(value: value, tint: tint, lineWidth: lineWidth, label: label)
        }
        .padding(lineWidth / 2)
    }
}

/// Widget of the menu grid: a glass card that lifts under the pointer and opens its detail sheet on click.
struct MenuTile<Content: View, Detail: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    /// Read by VoiceOver after the title.
    let summary: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let detail: () -> Detail
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    TileIcon(symbol: symbol, tint: tint, size: 22)
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                content()
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .glass(tint: tint, interactive: true, selected: shown)
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .help("Cliquez pour les détails")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
        .accessibilityHint("Affiche les détails")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $shown, arrowEdge: .leading) { detail() }
    }
}

/// What a process line asks the panel to stop: an app, quit cleanly, or the processes of a script (SIGTERM).
enum ProcessTarget {
    case app(NSRunningApplication)
    /// Each process keeps its sampled start time, checked again before the signal (a pid may have been reused).
    case processes(name: String, targets: [ProcessUsage])
}

/// Hungry process: icon, name, CPU and memory, and Quit when it is a regular app we may quit.
/// A script running several times (`members`) folds its processes under a chevron, each one stoppable.
struct ProcessRow: View {
    let process: ProcessUsage
    var showsCPU = true
    var showsMemory = true
    let quit: (ProcessTarget) -> Void
    @State private var expanded = false
    @ReducedMotion private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            line
            if expanded {
                ForEach(process.members) { m in memberLine(m) }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.callout)
        .animation(reduceMotion ? nil : DS.spring, value: expanded)
    }

    private var line: some View {
        let quitable = process.arguments.isEmpty ? MenuActions.runningApp(process) : nil
        let app = quitable ?? NSRunningApplication(processIdentifier: process.pid)
        return HStack(spacing: DS.Space.s) {
            if process.members.isEmpty {
                icon(app)
                Text(process.name).lineLimit(1).truncationMode(.middle).help(commandHelp(process))
            } else {
                Button { expanded.toggle() } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 16, height: 16)
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        Text("×\(process.members.count)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerStyle(.link)
                .help(expanded ? "Masquer les processus" : "Afficher les \(process.members.count) processus")
                .accessibilityLabel("\(process.name), \(process.members.count) processus")
                .accessibilityValue(expanded ? "Déplié" : "Replié")
            }
            Spacer(minLength: DS.Space.xs)
            figures(process)
            Group {
                if let quitable {
                    QuitButton(name: process.name) { quit(.app(quitable)) }
                } else if ProcessStopper.canStop(process) {
                    QuitButton(name: process.name, count: process.pids.count) { quit(.processes(name: process.name, targets: process.members.isEmpty ? [process] : process.members)) }
                } else {
                    // No app to quit: a padlock, and on hover a bubble saying why (not a missing permission).
                    let isSelf = process.pid == ProcessInfo.processInfo.processIdentifier || process.path == Bundle.main.bundlePath
                    LockReason(text: isSelf ? "C'est Vibe Cleaner : quittez-le depuis le menu « … »."
                        : process.isSystem ? "Processus de macOS : il ne se quitte pas comme une app."
                        : "Outil en ligne de commande ou en arrière-plan : arrêtez-le là où il a été lancé.")
                }
            }
            .frame(width: ProcessRow.actionWidth, alignment: .trailing)
        }
    }

    /// One process of a script: its pid and what follows the script on the command line, indented under the chevron.
    private func memberLine(_ m: ProcessUsage) -> some View {
        HStack(spacing: DS.Space.s) {
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 16).padding(.leading, 7).padding(.trailing, 8)
            Text("PID \(String(m.pid))").monospacedDigit().foregroundStyle(.secondary)
            Text(Self.options(m.arguments)).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: DS.Space.xs)
            figures(m)
            QuitButton(name: "le processus \(m.pid)", count: 1) { quit(.processes(name: process.name, targets: [m])) }
                .frame(width: ProcessRow.actionWidth, alignment: .trailing)
        }
        .help(commandHelp(m))
    }

    @ViewBuilder private func figures(_ p: ProcessUsage) -> some View {
        if showsCPU {
            Text("\(Int(p.cpuPercent)) %").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        if showsMemory {
            Text(FileSizer.format(p.memory)).monospacedDigit().foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
        }
    }

    private func icon(_ app: NSRunningApplication?) -> some View {
        Group {
            if let icon = app?.icon, process.arguments.isEmpty { Image(nsImage: icon).resizable() }
            else { Image(systemName: process.arguments.isEmpty ? "gearshape.fill" : "terminal.fill").foregroundStyle(.secondary) }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func commandHelp(_ p: ProcessUsage) -> String {
        p.arguments.isEmpty ? "" : "PID \(p.pid) : \(p.arguments.joined(separator: " "))"
    }

    /// The command line after the script, which tells workers apart ("--rank 2"); the script itself is in the title.
    static func options(_ args: [String]) -> String {
        guard let script = SystemSampler.script(args) else { return "" }
        let last = script.split(separator: " ").last.map(String.init) ?? script
        guard let i = args.firstIndex(where: { $0 == last || ($0 as NSString).lastPathComponent == last }) else { return "" }
        return args[(i + 1)...].joined(separator: " ")
    }

    static let actionWidth: CGFloat = 88
}

/// "Quitter" an app, or "Arrêter" a script's processes (`count`), then "Confirmer" on the same spot: the confirmation
/// stays in the panel, since a dialog would close the menu bar window and leave the question pending. Back after 4 s.
private struct QuitButton: View {
    let name: String
    /// Processes to stop; nil for an app, which is quit.
    var count: Int? = nil
    let action: () -> Void
    @State private var confirming = false

    private var verb: String { count == nil ? "Quitter" : count! > 1 ? "Tout arrêter" : "Arrêter" }

    private var help: String {
        guard let count else {
            return confirming ? "Cliquez encore pour quitter \(name). L'app vous demandera d'enregistrer vos documents." : "Quitter \(name)"
        }
        let what = count > 1 ? "les \(count) processus de \(name)" : name
        return confirming ? "Cliquez encore pour arrêter \(what). Comme Ctrl-C : le travail en cours non enregistré est perdu."
            : "Arrêter \(what)"
    }

    var body: some View {
        Button {
            if confirming { confirming = false; action() } else { confirming = true }
        } label: {
            Text(confirming ? "Confirmer" : verb).font(.caption.weight(.medium))
                .foregroundStyle(confirming ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
                .background(Capsule().fill(confirming ? AnyShapeStyle(Theme.critical) : AnyShapeStyle(Color.primary.opacity(0.1))))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .animation(.easeOut(duration: 0.15), value: confirming)
        .help(help)
        .accessibilityLabel(help)
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(4))
            confirming = false
        }
    }
}

/// Glass button that asks for a second click on the same spot ("Confirmer", in red) before acting.
/// The menu bar window closes under a dialog and leaves it pending, so the panel confirms in place. Resets after 4 s.
struct ConfirmButton<L: View>: View {
    var tint: Color? = nil
    var prominent = false
    /// Tooltip before the first click.
    var help = ""
    let confirmHelp: String
    let action: () -> Void
    @ViewBuilder let label: (_ confirming: Bool) -> L
    @State private var confirming = false

    var body: some View {
        Button {
            if confirming { confirming = false; action() } else { confirming = true }
        } label: { label(confirming) }
        .buttonStyle(GlassButtonStyle(tint: confirming ? Theme.critical : tint, prominent: confirming || prominent))
        .animation(.easeOut(duration: 0.15), value: confirming)
        .help(confirming ? confirmHelp : help)
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(4))
            confirming = false
        }
    }
}

/// Padlock for a line without "Quitter"; the reason shows in a bubble as soon as the pointer is on it.
private struct LockReason: View {
    let text: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: "lock.fill").font(.caption2)
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .padding(DS.Space.xs)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering, arrowEdge: .top) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(DS.Space.m)
            }
            .accessibilityLabel(text)
    }
}
