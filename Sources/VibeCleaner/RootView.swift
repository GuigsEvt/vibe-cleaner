import SwiftUI
import VibeCleanerCore

struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("onboardingDone") private var onboardingDone = false
    @ReducedMotion private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    static let tools: Set<String> = ["radar", "cloud"]

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.current }, set: { model.select($0) })) {
                Section { rows { $0.id == "vibecheck" } }
                Section("Modules") { rows { $0.id != "vibecheck" && !Self.tools.contains($0.id) } }
                Section("Outils") { rows { Self.tools.contains($0.id) } }
            }
            .safeAreaInset(edge: .bottom) { guideItem }
            .navigationSplitViewColumnWidth(min: 210, ideal: 244, max: 290)
        } detail: {
            ZStack {
                CanvasBackground(moduleID: model.current)
                detail
                    .id(model.current)
                    // A short glide and a fade, in the direction of the sidebar move; the screen's own entrances follow.
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: model.forward ? 36 : -36).combined(with: .opacity)
                                                                          .combined(with: .scale(scale: 0.985)),
                                                                      removal: .opacity.combined(with: .scale(scale: 1.01))))
            }
            .clipped()
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.88), value: model.current)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 640)
        .handCursorButtons()
        .background(MainWindowProbe())
        .sheet(isPresented: Binding(get: { !onboardingDone }, set: { if !$0 { onboardingDone = true } })) {
            OnboardingView { onboardingDone = true }.handCursorButtons()
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL(perform: open)
    }

    @ViewBuilder private var detail: some View {
        switch model.current {
        case "radar": RadarView(model: model.radar)
        case "guide": GuideView(model: model)
        default:
            if let run = model.runs[model.current] { ModuleScreen(run: run) }
        }
    }

    private func rows(_ include: (ModuleEntry) -> Bool) -> some View {
        ForEach(model.entries.filter(include)) { e in
            SidebarRow(symbol: e.symbol, title: e.title, tint: Theme.accent(e.id), selected: model.current == e.id) {
                if let run = model.runs[e.id] { badge(run) }
            }
            .tag(e.id)
        }
    }

    private var guideItem: some View {
        Button { model.select("guide") } label: {
            SidebarRow(symbol: "bubble.left.and.text.bubble.right", title: "Le Guide", tint: Theme.accent("guide"),
                       selected: model.current == "guide") { EmptyView() }
                .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                .glass(tint: model.current == "guide" ? Theme.accent("guide") : nil, radius: DS.Radius.control + 2,
                       interactive: true, selected: model.current == "guide")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityAddTraits(model.current == "guide" ? .isSelected : [])
        .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.m)
    }

    /// `vibecleaner://module/<id>` and `vibecleaner://settings`.
    private func open(_ url: URL) {
        guard url.scheme == "vibecleaner" else { return }
        switch url.host() {
        case "module":
            let id = url.pathComponents.dropFirst().first ?? ""
            if model.runs[id] != nil || id == "guide" { model.select(id); model.show(id) }
            else { Log("app").info("Lien profond inconnu : \(url.absoluteString)") }
        case "settings": openSettings()
        default: Log("app").info("Lien profond inconnu : \(url.absoluteString)")
        }
    }

    @ViewBuilder private func badge(_ run: ModuleRun) -> some View {
        switch run.phase {
        case .scanning, .executing: ProgressView().controlSize(.small).accessibilityLabel("En cours")
        case .results:
            // The selection, as the tiles show it; a check mark rather than "Zéro ko" when nothing is left.
            if run.selectedSize > 0 {
                Text(FileSizer.format(run.selectedSize)).font(.caption2.weight(.semibold).monospacedDigit())
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.accent(run.entry.id).opacity(0.22), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent(run.entry.id).opacity(0.35), lineWidth: 0.5))
            }
            else if run.allGroups.isEmpty { Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Rien à signaler") }
        case .summary: Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.accent(run.entry.id)).accessibilityLabel("Terminé")
        case .intro: EmptyView()
        }
    }
}

/// Sidebar line: the module symbol in a pastille of its colour, the title, and a trailing badge.
struct SidebarRow<Badge: View>: View {
    let symbol: String
    let title: String
    let tint: Color
    var selected = false
    @ViewBuilder var badge: () -> Badge
    @State private var hovering = false
    @ReducedMotion private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? .white : tint)
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                                       : AnyShapeStyle(tint.opacity(0.16)))
                }
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(selected ? 0.3 : 0.08), lineWidth: 0.5))
                .shadow(color: selected ? tint.opacity(0.5) : hovering ? tint.opacity(0.3) : .clear, radius: 6, y: 2)
                .scaleEffect(hovering && !selected && !reduceMotion ? 1.08 : 1)
                .animation(DS.spring, value: selected)
                .animation(DS.spring, value: hovering)
                .accessibilityHidden(true)
            Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1).minimumScaleFactor(0.85).layoutPriority(1)
            Spacer(minLength: DS.Space.xs)
            badge()
        }
        .padding(.vertical, 3)
        // Hover: a soft wash behind the line (the selection keeps the system highlight).
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(tint.opacity(hovering && !selected ? 0.12 : 0))
                .padding(.horizontal, -DS.Space.s)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}
