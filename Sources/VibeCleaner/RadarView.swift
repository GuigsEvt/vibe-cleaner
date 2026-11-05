import QuickLook
import SwiftUI
import VibeCleanerCore

@MainActor @Observable
final class RadarModel {
    var root: SpaceNode?
    var current: SpaceNode?
    var history = SpaceHistory()
    var scanning = false
    var scannedBytes: Int64 = 0
    var files = 0
    var currentPath = ""
    /// Paths ticked in the list, removed together after review.
    var selected: Set<String> = []
    /// Purgeable space of the scanned volume (0 for a folder scan).
    var purgeable: Int64 = 0
    /// Volume holding the scanned folder, for the gauge.
    var volume: VolumeInfo?
    var error: String?
    /// Last grouped removal and where its journal was saved.
    var lastRemoval: (log: CleanupLog, url: URL?)?
    /// Bumped after each removal so views reading mutated nodes refresh.
    var revision = 0
    /// A removal is running off the main thread.
    var removing = false
    private var task: Task<Void, Never>?
    /// Bumped by each scan: progress and results of an older scan still finishing are ignored.
    private var generation = 0

    var toRemove: [SpaceNode] { SpaceNode.outermost(selected).compactMap { root?.node(at: $0) } }
    var selectedBytes: Int64 { toRemove.reduce(0) { $0 + $1.size } }

    func scan(_ url: URL, purgeable: Int64 = 0) {
        start(purgeable: purgeable, volumeOf: url) { scanner, progress in try await scanner.scan(root: url, progress: progress) }
    }

    /// iCloud Drive and `~/Library/CloudStorage` under one root; placeholders are never downloaded.
    func scanCloud() {
        let roots = SpaceScanner.cloudRoots()
        guard !roots.isEmpty else { error = "Aucun dossier iCloud Drive ni CloudStorage sur ce Mac."; return }
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        start(purgeable: 0, volumeOf: library) { scanner, progress in
            try await scanner.scan(roots: roots, name: "Stockage cloud", container: library, progress: progress)
        }
    }

    private func start(purgeable: Int64, volumeOf url: URL,
                       run: @escaping @Sendable (SpaceScanner, @escaping SpaceScanner.Progress) async throws -> SpaceNode) {
        task?.cancel()
        scanning = true
        scannedBytes = 0
        files = 0
        selected = []
        history.reset()
        lastRemoval = nil
        error = nil
        self.purgeable = purgeable
        volume = SpaceScanner.volume(containing: url)
        generation += 1
        let gen = generation
        task = Task {
            let node = try? await run(SpaceScanner()) { bytes, files, path in
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.scannedBytes = bytes
                    self.files = files
                    self.currentPath = path
                }
            }
            guard generation == gen else { return }
            root = node
            current = node
            scanning = false
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
    }

    func close() {
        root = nil
        current = nil
        history.reset()
        lastRemoval = nil
    }

    func go(to node: SpaceNode) {
        guard let current, node !== current else { return }
        history.visit(from: current, to: node)
        self.current = node
    }

    func goBack() {
        guard let current, let root, let n = history.goBack(from: current, in: root) else { return }
        self.current = n
    }

    func goForward() {
        guard let current, let root, let n = history.goForward(from: current, in: root) else { return }
        self.current = n
    }

    func goUp() {
        if let parent = current?.parent { go(to: parent) }
    }

    func toggle(_ node: SpaceNode) {
        let path = node.path
        if selected.contains(path) { selected.remove(path); return }
        let prefix = path + "/"
        selected = selected.filter { !$0.hasPrefix(prefix) }
        selected.insert(path)
    }

    func trashSelection() { trash(toRemove) }

    /// One grouped removal through `SafeRemover` (Trash), off the main thread, then the tree and its journal are
    /// updated. The freed size shown is the nodes' size from the map.
    func trash(_ nodes: [SpaceNode]) {
        guard let root, !nodes.isEmpty, !removing else { return }
        let remover = Prefs.context().remover
        let urls = nodes.map(\.url)
        let gen = generation
        removing = true
        Task {
            let report = await Task.detached { remover.remove(urls, mode: .trash) }.value
            removing = false
            // A new scan replaced the map meanwhile: nothing to update in it.
            guard generation == gen, self.root === root else { return }
            applied(report, to: root, dryRun: remover.dryRun)
        }
    }

    private func applied(_ report: RemovalReport, to root: SpaceNode, dryRun: Bool) {
        let here = current?.path ?? root.path
        let log = root.apply(report, dryRun: dryRun)
        lastRemoval = (log, try? log.save())
        let gone = log.processed
        selected = selected.filter { p in !gone.contains { p == $0 || p.hasPrefix($0 + "/") } }
        current = root.nearest(to: here)
        revision += 1
        error = report.failures.isEmpty ? nil : "\(report.failures.count) élément(s) non supprimé(s), laissés sélectionnés : \(report.failures.map(\.1).joined(separator: " ; "))"
    }
}


struct RadarView: View {
    @Bindable var model: RadarModel
    @State private var hovered: String?
    @State private var confirmTrash: SpaceNode?
    @State private var reviewing = false
    @State private var showOthers = false
    @State private var purgeableInfo = false
    @State private var preview: URL?
    @State private var confirmClose = false
    @State private var confirmStop = false

    static let cloudWarning = "Ce dossier est synchronisé : le mettre à la Corbeille le supprime aussi du cloud, sur tous vos appareils."
    static let accent = Theme.accent("radar")

    /// iCloud Drive, File Provider folders and Desktop / Documents synced by iCloud: a local deletion propagates to the cloud.
    static func isCloud(_ path: String) -> Bool { SpaceNode.isCloudSynced(path: path) }

    var body: some View {
        VStack(spacing: 0) {
            if model.scanning {
                Spacer()
                ProgressScreen(title: "Construction de la carte", fraction: nil,
                               step: "\(FileSizer.format(model.scannedBytes)) · \(model.files.formatted()) fichiers — \(model.currentPath)", moduleID: "radar")
                    .entrance(0)
                Spacer()
                ActionButton(title: "Arrêter", moduleID: "radar") { confirmStop = true }.padding(.top, 16).padding(.bottom, 22)
            } else if let node = model.current {
                let level = bubbles(node)
                breadcrumb(node).entrance(0)
                if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.critical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                        .glass(tint: Theme.critical, radius: DS.Radius.control)
                        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.s)
                }
                if let r = model.lastRemoval { removalBanner(r.log, url: r.url) }
                HSplitView {
                    list(node, level: level)
                        .padding(.leading, DS.Space.l).padding(.trailing, DS.Space.xs).padding(.vertical, DS.Space.xs)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                        .entrance(1)
                    BubbleChart(bubbles: level, selected: model.selected, hovered: $hovered, tooltip: tooltip, open: open, up: model.goUp,
                                menu: { AnyView(menu(for: $0)) })
                        .padding(DS.Space.l)
                        .entrance(2)
                }
                footer.entrance(3)
            } else {
                RadarPicker(model: model)
            }
        }
        .quickLookPreview($preview)
        .sheet(isPresented: $reviewing) { SpaceReview(model: model) { reviewing = false }.handCursorButtons() }
        .alert("Espace purgeable", isPresented: $purgeableInfo) { Button("OK") {} } message: { Text(purgeableExplanation) }
        .confirmationDialog("Mettre « \(confirmTrash?.name ?? "") » à la Corbeille ?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } }),
                            titleVisibility: .visible) {
            Button(confirmTrash.map { Self.isCloud($0.path) } == true ? "Supprimer aussi du cloud" : "Mettre à la Corbeille", role: .destructive) {
                if let n = confirmTrash { model.trash([n]) }
                confirmTrash = nil
            }
        } message: {
            Text(confirmTrash.map { Self.isCloud($0.path) } == true ? Self.cloudWarning : "Vous pourrez le récupérer dans la Corbeille.")
        }
        .confirmationDialog("Recommencer ?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Recommencer", role: .destructive) { model.close() }
        } message: {
            Text(model.selected.isEmpty ? "La carte sera fermée ; il faudra relancer l'analyse." : "La carte et la sélection en cours seront perdues.")
        }
        .confirmationDialog("Voulez-vous arrêter l'analyse avant la fin ?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Arrêter", role: .destructive) { model.stop() }
            Button("Continuer l'analyse", role: .cancel) {}
        }
        .onChange(of: model.current?.id) { showOthers = false }
    }

    private func bubbles(_ node: SpaceNode) -> [SpaceBubble] {
        _ = model.revision
        var list = VibeCleanerCore.bubbles(for: node)
        if node === model.root, model.purgeable > 0 { list.append(purgeableBubble(model.purgeable)) }
        return list
    }

    private func enterable(_ n: SpaceNode) -> Bool { n.isDirectory && !n.isPackage && !n.children.isEmpty }

    private func open(_ b: SpaceBubble) {
        if let n = b.node { if enterable(n) { model.go(to: n) } }
        else if b.id == purgeableBubble(0).id { purgeableInfo = true }
        else { showOthers = true }
    }

    private func tooltip(_ b: SpaceBubble) -> String {
        if let n = b.node { return n.tooltip(selected: model.selected) }
        if b.id == purgeableBubble(0).id { return "Espace purgeable — \(FileSizer.format(b.size))\n\(purgeableExplanation)" }
        return "\(smallerItemsExplanation)\n\(b.others.count) éléments — \(FileSizer.format(b.size))"
    }

    @ViewBuilder
    private func menu(for n: SpaceNode) -> some View {
        Button("Coup d'œil") { preview = n.url }
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
        Button("Copier le chemin") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(n.path, forType: .string)
        }
        if !n.isProtected {
            Button(model.selected.contains(n.path) ? "Désélectionner" : "Sélectionner") { model.toggle(n) }
            Button(Self.isCloud(n.path) ? "Mettre à la Corbeille (supprime aussi du cloud)…" : "Mettre à la Corbeille…") { confirmTrash = n }
        }
    }

    /// Restart, history and the path as glass chips; the level's size on the right.
    private func breadcrumb(_ node: SpaceNode) -> some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 2) {
                navButton("xmark", help: "Recommencer") { confirmClose = true }
                navButton("chevron.left", help: "Précédent") { model.goBack() }
                    .disabled(!model.history.canGoBack).keyboardShortcut("[", modifiers: .command)
                navButton("chevron.right", help: "Suivant") { model.goForward() }
                    .disabled(!model.history.canGoForward).keyboardShortcut("]", modifiers: .command)
            }
            .padding(3)
            .glass(radius: 17)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(node.ancestry) { n in
                        let last = n === node
                        Button { model.go(to: n) } label: {
                            Label(n.name.isEmpty ? "/" : n.name, systemImage: n.parent == nil ? "internaldrive" : "folder")
                                .labelStyle(.titleAndIcon)
                                .font(.callout.weight(last ? .semibold : .regular))
                                .foregroundStyle(last ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(last ? Self.accent.opacity(0.22) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).pointerStyle(.link)
                        if !last { Image(systemName: "chevron.compact.right").font(.callout).foregroundStyle(.tertiary) }
                    }
                }
                .padding(3)
                .glass(radius: 17)
            }
            .scrollClipDisabled()
            Spacer(minLength: 0)
            Text(FileSizer.format(node.size)).font(.title3.bold().monospacedDigit())
                .padding(.horizontal, DS.Space.m).padding(.vertical, 5)
                .glass(tint: Self.accent, radius: 17)
                .accessibilityLabel("Taille du niveau : \(FileSizer.format(node.size))")
        }
        .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m).padding(.bottom, DS.Space.s)
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(RadarRoundButtonStyle())
        .help(help).accessibilityLabel(help)
    }

    private func list(_ node: SpaceNode, level: [SpaceBubble]) -> some View {
        let others = level.first { $0.isAggregate && $0.id != purgeableBubble(0).id }
        let total = max(1, node.size)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(node.name.isEmpty ? "/" : node.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(node.children.count.formatted()) éléments").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Space.l).padding(.top, DS.Space.m).padding(.bottom, DS.Space.xs)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(level.compactMap(\.node)) { row($0, hoverID: $0.path, total: total) }
                if let others {
                    DisclosureGroup(isExpanded: $showOthers) {
                        ForEach(others.others) { row($0, hoverID: others.id, total: total) }
                    } label: {
                        HStack {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 20)
                            Text("\(others.name) (\(others.others.count))").foregroundStyle(.secondary)
                            Spacer()
                            Text(FileSizer.format(others.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .help(showOthers ? "Masquer les autres éléments" : "Afficher les autres éléments")
                    }
                    .padding(.horizontal, DS.Space.s)
                    .background(rowHighlight(hovered == others.id))
                }
                }
                .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            }
            .scrollContentBackground(.hidden)
        }
        .glass(tint: Self.accent.opacity(0.5), radius: DS.Radius.tile)
    }

    private func rowHighlight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(on ? Self.accent.opacity(0.2) : .clear)
    }

    /// `hoverID` is the bubble the row belongs to: itself, or the aggregate for folded items.
    private func row(_ child: SpaceNode, hoverID: String, total: Int64) -> some View {
        let sel = child.selection(in: model.selected)
        let viaParent = sel.entire && !model.selected.contains(child.path)
        return HStack(spacing: DS.Space.s) {
            if !child.isProtected {
                TriCheck(state: sel.entire ? .on : sel.bytes > 0 ? .mixed : .off) { model.toggle(child) }
                    .disabled(viaParent)
                    .accessibilityLabel("Sélectionner \(child.name)")
                    .accessibilityValue(sel.entire ? "coché" : sel.bytes > 0 ? "partiellement coché" : "non coché")
            } else {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary).frame(width: 16)
                    .help("Dossier système").accessibilityLabel("Dossier système")
            }
            Image(nsImage: IconCache.icon(child.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(child.name).lineLimit(1).truncationMode(.middle)
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Self.accent.gradient)
                                .frame(width: max(2, geo.size.width * CGFloat(Double(child.size) / Double(total))))
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(FileSizer.format(child.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.vertical, 6).padding(.horizontal, DS.Space.s)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(rowHighlight(hovered == hoverID))
        .onHover { hovered = $0 ? hoverID : (hovered == hoverID ? nil : hovered) }
        .help(child.tooltip(selected: model.selected))
        .onTapGesture(count: 2) { if enterable(child) { model.go(to: child) } }
        .contextMenu { menu(for: child) }
    }

    /// Gauge and selection side by side, stacked when the window is too narrow for both.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.l) {
                gauge
                Spacer()
                selectionControls
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                gauge
                HStack(spacing: DS.Space.m) {
                    Spacer()
                    selectionControls
                }
            }
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .glass(tint: Self.accent.opacity(0.4), radius: DS.Radius.tile)
        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.l).padding(.top, DS.Space.xs)
    }

    @ViewBuilder private var gauge: some View {
        if let v = model.volume { RadarGauge(gauge: VolumeGauge(volume: v, selected: model.selectedBytes)).frame(width: 340) }
    }

    @ViewBuilder private var selectionControls: some View {
        if !model.selected.isEmpty {
            VStack(alignment: .trailing, spacing: 0) {
                Text(FileSizer.format(model.selectedBytes)).font(.headline.monospacedDigit()).foregroundStyle(Theme.warning)
                Text("\(model.toRemove.count) élément(s) sélectionné(s)").font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1).fixedSize()
            .accessibilityElement(children: .combine)
            Button("Tout désélectionner") { model.selected = [] }.buttonStyle(GlassButtonStyle())
            Button { reviewing = true } label: { Label("Revoir et supprimer…", systemImage: "trash") }
                .buttonStyle(GlassButtonStyle(tint: Self.accent.deepened, prominent: true))
                .keyboardShortcut(.defaultAction)
        } else {
            Text("Cochez des éléments dans la liste pour les revoir puis les supprimer.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    private func removalBanner(_ log: CleanupLog, url: URL?) -> some View {
        let ok = log.failures.isEmpty
        return HStack(spacing: DS.Space.s) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3).foregroundStyle(ok ? Self.accent : Theme.warning)
            Text("\(log.processed.count) élément(s) mis à la Corbeille, \(FileSizer.format(log.freedBytes))\(log.dryRun ? " (simulation)" : "")")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Copier le journal") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.text, forType: .string)
            }
            .buttonStyle(GlassButtonStyle())
            if let url { Button("Journal de suppression") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(GlassButtonStyle()) }
            Button { model.lastRemoval = nil } label: { Image(systemName: "xmark").font(.caption.bold()) }.buttonStyle(.borderless).pointerStyle(.link)
                .help("Masquer").accessibilityLabel("Masquer ce message")
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .glass(tint: ok ? Self.accent : Theme.warning, radius: DS.Radius.card)
        .padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.s)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Small round glass button of the Radar toolbar.
struct RadarRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RoundBody(configuration: configuration).pointerStyle(.link) }

    private struct RoundBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.2 : hovering ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(enabled ? 1 : 0.35)
                .animation(DS.spring, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Review before removal: every selected item with its size, then one confirmation.
struct SpaceReview: View {
    let model: RadarModel
    let close: () -> Void

    var body: some View {
        let nodes = model.toRemove
        let accent = RadarView.accent
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                ZStack {
                    Circle().fill(accent.opacity(0.22))
                    Image(systemName: "trash.fill").font(.system(size: 20)).foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mettre \(nodes.count) élément(s) à la Corbeille ?").font(.title3.bold())
                    Text("\(FileSizer.format(nodes.reduce(0) { $0 + $1.size })) au total, y compris le contenu des dossiers sélectionnés. Vous pourrez les récupérer dans la Corbeille.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            let cloud = nodes.filter { RadarView.isCloud($0.path) }
            if !cloud.isEmpty {
                Label("\(cloud.count) élément(s) sont dans un dossier synchronisé (iCloud Drive, Google Drive, OneDrive…) : les mettre à la Corbeille les supprime aussi du cloud, sur tous vos appareils.",
                      systemImage: "icloud.slash")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(tint: Theme.warning, radius: DS.Radius.control)
            }
            List(nodes) { n in
                HStack(spacing: DS.Space.s) {
                    Image(nsImage: IconCache.icon(n.path)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.name).lineLimit(1)
                        Text(n.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if RadarView.isCloud(n.path) { Image(systemName: "icloud").foregroundStyle(Theme.warning).help("Supprimé aussi du cloud").accessibilityLabel("Dans le cloud") }
                    Text(FileSizer.format(n.size)).monospacedDigit().foregroundStyle(.secondary)
                    Button { model.selected.remove(n.path) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless).pointerStyle(.link)
                        .help("Retirer de la sélection").accessibilityLabel("Retirer \(n.name) de la sélection")
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 200)
            .glass(radius: DS.Radius.card)
            HStack {
                Button("Annuler", role: .cancel, action: close).keyboardShortcut(.cancelAction).buttonStyle(GlassButtonStyle())
                Spacer()
                Button(role: .destructive) { model.trashSelection(); close() } label: { Label("Mettre à la Corbeille", systemImage: "trash") }
                    .buttonStyle(GlassButtonStyle(tint: Theme.critical, prominent: true))
                    .disabled(nodes.isEmpty || model.removing)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 600, height: 460)
        .background {
            ZStack {
                Color(red: 0.07, green: 0.06, blue: 0.11)
                RadialGradient(colors: [accent.opacity(0.3), .clear], center: .topLeading, startRadius: 10, endRadius: 520)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
