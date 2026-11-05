import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers
import SwiftUI
import VibeCleanerCore

struct ResultsView: View {
    @Bindable var run: ModuleRun
    @State private var focused: String?
    @State private var sort: ResultSort = .size
    @State private var ascending = false
    @State private var filter: ResultFilter = .all
    @State private var search = ""
    @State private var preview: URL?
    /// Every image of a series, to flip through with the arrows in Quick Look; empty for a single file.
    @State private var previewSet: [URL] = []
    /// Source and vendor filters of an app list (`ResultGroup.tags`); empty shows everything.
    @State private var facets: [String: String] = [:]

    /// Results shown: all, or only the reviewed tile (a module in Vibe Check, a group elsewhere).
    private var visible: [ModuleResults] {
        guard let r = run.reviewing else { return run.results }
        if run.results.contains(where: { $0.module.id == r }) { return run.results.filter { $0.module.id == r } }
        return run.results.map { ModuleResults(module: $0.module, groups: $0.groups.filter { $0.id == r }) }.filter { !$0.groups.isEmpty }
    }
    private var tint: Color { Theme.accent(run.entry.id) }
    private var visibleItems: [ResultItem] { visible.flatMap(\.groups).flatMap(\.allItems) }
    /// Each reviewed item once, for the counter of the reviewed scope; notes and links are not choices.
    private var visibleUnique: [ResultItem] { var s = Set<String>(); return visibleItems.filter { $0.isActionable && s.insert($0.id).inserted } }
    /// Nothing to choose here (updates, links): the header counts the rows instead of a selection.
    private var readOnly: Bool { visibleUnique.isEmpty && !visibleItems.isEmpty }
    /// Every app, every big file…: chosen one by one, never all at once.
    private var oneByOne: Bool { !run.isVibeCheck && run.reviewing.map(ResultQueries.oneByOneGroupIDs.contains) == true }
    /// Items the "Sélection" menu may tick: a card's bulk items in Vibe Check, the reviewed group's own box elsewhere.
    private var visibleBulk: [ResultItem] {
        let groups = visible.flatMap(\.groups)
        if run.isVibeCheck { return groups.flatMap(\.bulkItems) }
        // A filtered app list: "Tout sélectionner" never picks the apps the filter hides.
        return groups.flatMap { g in g.items.filter(\.isActionable) + g.groups.filter { $0.matches(facets) }.flatMap(\.bulkItems) }
    }

    var body: some View {
        Group {
            if run.allGroups.isEmpty {
                VStack(spacing: DS.Space.m) {
                    GlowSymbol(symbol: "checkmark.seal.fill", tint: tint, size: 100).padding(.bottom, DS.Space.s)
                    Text("Tout est en ordre").font(.title.bold()).entrance(1)
                    Text("Il n'y a rien à nettoyer ou corriger ici.").foregroundStyle(.secondary).entrance(2)
                }
                // Centred in the page, not hugging the leading edge.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Two glass panels side by side. A plain stack rather than HSplitView: the split view sized the category
                // list at its minimum width, then widened the pane without reflowing the rows.
                GeometryReader { geo in
                    HStack(spacing: DS.Space.m) {
                        categories
                            .glass(tint: tint, radius: DS.Radius.tile)
                            .frame(width: min(340, max(260, geo.size.width * 0.36)))
                            .entrance(0)
                        details
                            .glass(tint: tint, radius: DS.Radius.tile)
                            .frame(maxWidth: .infinity)
                            .entrance(1)
                    }
                    .padding([.horizontal, .bottom], DS.Space.l)
                }
                .onAppear { focused = visible.flatMap(\.groups).first?.id }
                .onChange(of: focused) { facets = [:] }
            }
        }
        .quickLookPreview($preview, in: previewSet.isEmpty ? preview.map { [$0] } ?? [] : previewSet)
        .overlay(alignment: .bottom) {
            if let undo = run.lastIgnore {
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash")
                    Text("« \(undo.name) » a été ajouté à la liste d'exclusion").lineLimit(1).truncationMode(.middle)
                    Button("Remettre") { run.undoIgnore() }.help("Retirer cet élément de la liste d'exclusion")
                    .buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, 10)
                .glass(tint: tint, radius: 22)
                .padding(.bottom, DS.Space.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: run.lastIgnore?.rule)
    }

    /// Replaces the selection inside the reviewed scope only; other tiles keep theirs.
    private func select(_ ids: Set<String>) {
        run.selection.subtract(visibleItems.map(\.id))
        run.selection.formUnion(ids)
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 0) {
            let picked = visibleUnique.filter { run.selection.contains($0.id) }.reduce(0) { $0 + $1.size }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    if !readOnly && !oneByOne { Menu("Sélection") {
                        Button("Sélection intelligente") {
                            let defaults = visible.flatMap(\.groups).reduce(into: Set<String>()) { $0.formUnion($1.defaultSelection) }
                            select(defaults.intersection(visibleBulk.map(\.id)).subtracting(RiskAcceptance.shared.ids))
                        }
                        Button("Tout sélectionner") { select(Set(visibleBulk.map(\.id))) }
                        Button("Tout désélectionner") { select([]) }
                        Divider()
                        ForEach(QuickSelection.allCases) { q in
                            Button(q.title) { select(q.pick(visibleBulk)) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(GlassButtonStyle())
                    .fixedSize()
                    .help("Plus gros, plus petits, plus récents, plus anciens : le quart des éléments à ce bout du classement") }
                }
                // Counter of the reviewed scope, on its own line so it never truncates at 980 pt.
                // Items without size (networks, permissions, processes) are counted rather than weighed.
                let total = visibleUnique.reduce(0) { $0 + $1.size }
                let count = visibleUnique.filter { run.selection.contains($0.id) }.count
                if readOnly {
                    let n = Set(visibleItems.map(\.id)).count
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(n)").font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                        Text("\(n > 1 ? "éléments" : "élément") à consulter, rien à sélectionner").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(total > 0 ? FileSizer.format(picked) : count == 0 ? "Aucun" : "\(count)")
                        .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText()).animation(.smooth, value: count)
                    Text(total > 0 ? "sélectionnés sur \(FileSizer.format(total))"
                                   : "sélectionné\(count > 1 ? "s" : "") sur \(countLabel(visibleUnique.count, "élément", "éléments"))")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
                }
            }.padding(DS.Space.m)
            Divider().opacity(0.5).padding(.horizontal, DS.Space.m)
            List(selection: $focused) {
                ForEach(visible.indices, id: \.self) { i in
                    let r = visible[i]
                    // One module: no section, which would draw an empty header band.
                    if visible.count > 1 { Section(r.module.title) { groupRows(r) } } else { groupRows(r) }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func groupRows(_ r: ModuleResults) -> some View {
        ForEach(r.groups) { g in
            let accent = Theme.accent(run.isVibeCheck ? r.module.id : run.entry.id)
            HStack(spacing: DS.Space.s) {
                // No box where it would tick every app at once, nor where there is nothing to tick (updates).
                if (!run.isVibeCheck || !g.bulkSelectable) && ResultQueries.oneByOneGroupIDs.contains(g.id) || !g.allItems.contains(where: \.isActionable) {
                    Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
                } else {
                    TriCheck(state: ResultQueries.boxState(tick: g.tickItems, all: g.allItems, selection: run.selection), label: g.title, tint: accent) {
                        run.toggle(g)
                    }
                }
                TintedIcon(symbol: g.symbol, tint: accent, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.title).fontWeight(.medium).lineLimit(1)
                    let accepted = g.allItems.filter { RiskAcceptance.shared.contains($0.id) }.count
                    Text(countLabel(g.allItems.count, "élément", "éléments").capitalizedFirst + (accepted > 0 ? " · \(accepted) accepté\(accepted > 1 ? "s" : "")" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.xs)
                if g.totalSize > 0 { Text(FileSizer.format(g.totalSize)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 3)
            .tag(g.id)
        }
    }

    private var searchField: some View {
        TextField("Rechercher…", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 220)
    }

    @ViewBuilder private var listControls: some View {
        Picker("Afficher", selection: $filter) { ForEach(ResultFilter.allCases) { Text($0.title).tag($0) } }
            .labelsHidden().fixedSize().help("Afficher")
        Picker("Trier", selection: $sort) { ForEach(ResultSort.allCases) { Text($0.title).tag($0) } }.labelsHidden().fixedSize()
        Button { ascending.toggle() } label: { Image(systemName: ascending ? "arrow.up" : "arrow.down") }
            .buttonStyle(.borderless).pointerStyle(.link)
            .help(ascending ? "Ordre inversé" : "Ordre par défaut")
            .accessibilityLabel(ascending ? "Ordre inversé" : "Ordre par défaut")
    }

    @ViewBuilder private var details: some View {
        if let g = visible.flatMap(\.groups).first(where: { $0.id == focused }) {
            let owner = run.isVibeCheck ? visible.first { $0.groups.contains { $0.id == g.id } }?.module.id ?? run.entry.id : run.entry.id
            let acceptsRisk = Self.acceptsRisk(owner: owner, group: g.id)
            let content = GroupContent(group: g, run: run, sort: sort, ascending: ascending, filter: filter, search: search,
                                       tint: Theme.accent(owner), acceptsRisk: acceptsRisk, facets: facets) { urls in
                previewSet = urls.count > 1 ? urls : []
                preview = urls.first
            }
            VStack(alignment: .leading, spacing: 8) {
                // Title on its own lines, controls below: fits the 980 pt minimum window.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: g.symbol).font(.title3).foregroundStyle(tint).accessibilityHidden(true)
                        Text(g.title).font(.title2.bold()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: DS.Space.s)
                        Text(g.totalSize > 0 ? FileSizer.format(g.totalSize) : countLabel(g.allItems.count, "élément", "éléments"))
                            .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let s = g.subtitle { Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    if acceptsRisk { GroupRiskButton(ids: g.allItems.map(\.id), run: run) }
                    // One row when it fits, the search field above the menus otherwise (980 pt window).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Space.s) { searchField; listControls; Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: DS.Space.s) { searchField; HStack(spacing: DS.Space.s) { listControls } }
                    }
                    if !g.facetKeys.isEmpty {
                        FacetBar(group: g, facets: $facets, tint: Theme.accent(owner))
                    }
                }.padding([.horizontal, .top], DS.Space.l)
                Divider().opacity(0.5).padding(.horizontal, DS.Space.l)
                if content.matches(g) {
                    List { content }.scrollContentBackground(.hidden)
                } else {
                    Text(!search.isEmpty ? "Aucun résultat pour « \(search) »" : facets.isEmpty ? "Aucun élément à afficher" : "Aucune app pour ce filtre")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            Label("Choisissez une catégorie", systemImage: "sidebar.left").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ResultsView {
    /// Protection findings the user may live with (items to check, privacy traces); never sure detections.
    static func acceptsRisk(owner: String, group: String) -> Bool {
        owner == "protection" && !ProtectionModule.confirmedGroupIDs.contains(group)
    }
}

/// "J'accepte ce risque" for a whole group (363 known Wi-Fi networks are not accepted one by one), or its undo.
struct GroupRiskButton: View {
    let ids: [String]
    let run: ModuleRun

    var body: some View {
        let all = !ids.isEmpty && ids.allSatisfy(RiskAcceptance.shared.contains)
        Button { run.acceptRisk(ids, !all) } label: {
            Label(all ? "Ne plus accepter le risque" : "J'accepte ce risque pour tout le groupe",
                  systemImage: all ? "arrow.uturn.backward" : "checkmark.shield")
        }
        .buttonStyle(GlassButtonStyle())
        .help(all ? "Ces éléments compteront de nouveau dans la note de santé."
                  : "Les éléments restent listés à chaque analyse, marqués « Risque accepté », mais ne comptent plus dans la note de santé.")
    }
}

struct GroupContent: View {
    let group: ResultGroup
    let run: ModuleRun
    let sort: ResultSort
    var ascending = false
    let filter: ResultFilter
    let search: String
    /// Accent of the module the group belongs to, for the boxes.
    var tint: Color = .accentColor
    var acceptsRisk = false
    /// Applied to the subgroups that carry tags (apps); nested groups pass it on unchanged.
    var facets: [String: String] = [:]
    let preview: ([URL]) -> Void

    var body: some View {
        if group.id == "applications.macos" {
            Button("Ouvrir Mise à jour de logiciels") { NSWorkspace.shared.open(SystemUpdates.settingsURL) }
        } else if group.id == "applications.updates", group.items.contains(where: { $0.openLink?.scheme == "macappstore" }) {
            Button("Ouvrir les mises à jour de l'App Store") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
        }
        ForEach(sort.sorted(group.groups.filter(matches), ascending: ascending), id: \.id) { sub in
            DisclosureGroup {
                GroupContent(group: sub, run: run, sort: sort, ascending: ascending, filter: filter, search: search, tint: tint,
                             acceptsRisk: acceptsRisk, preview: preview)
            } label: {
                let check = TriCheck(state: ResultQueries.boxState(tick: sub.tickItems, all: sub.allItems, selection: run.selection),
                                     label: sub.title, tint: tint, size: 18) { run.toggle(sub) }
                Group { if let app = ApplicationsModule.appURL(groupID: sub.id) {
                    AppRow(group: sub, app: app, check: check)
                } else {
                    HStack(spacing: DS.Space.s) {
                        check
                        // A copy set shows the file's own icon: a photo, a PDF, a video read at a glance.
                        if sub.keepsFirst, let url = sub.items.first?.url {
                            Thumbnail(url: url, side: 32)
                        } else {
                            Image(systemName: sub.symbol).frame(width: 18)
                        }
                        Text(sub.title).lineLimit(1)
                        if let s = sub.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if sub.keepsFirst, sub.items.contains(where: { $0.url.map(Thumbnail.isImage) == true }) {
                            Button { preview(sub.items.compactMap(\.url)) } label: { Label("Comparer", systemImage: "eye") }
                                .buttonStyle(GlassButtonStyle(tint: tint))
                                .help("Ouvre les \(sub.items.count) images dans Coup d'œil : flèches ← → pour passer de l'une à l'autre")
                        }
                        if sub.totalSize > 0 { Text(FileSizer.format(sub.totalSize)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, DS.Space.xs)
                } }
                .contextMenu {
                    if ApplicationsModule.isAppGroup(sub.id) {
                        Button("Réinitialiser (garder l'app, effacer ses données)") {
                            run.selection.subtract(sub.allItems.map(\.id))
                            run.selection.formUnion(ApplicationsModule.resetSelection(sub))
                        }
                    }
                }
            }
        }
        // A copy set keeps its order: the copy to keep first, as its box assumes.
        let rows = group.keepsFirst ? group.items.filter(matches) : sort.sorted(group.items.filter(matches), ascending: ascending)
        ForEach(rows) { item in
            ItemRow(item: item, run: run, tint: tint, acceptsRisk: acceptsRisk,
                    kept: group.keepsFirst && item.id == group.items.first?.id, preview: preview)
        }
    }

    func matches(_ g: ResultGroup) -> Bool {
        guard g.matches(facets) else { return false }
        if search.isEmpty && filter == .all && facets.isEmpty { return true }
        if filter == .all && g.title.localizedCaseInsensitiveContains(search) { return true }
        return g.allItems.contains(where: matches)
    }
    func matches(_ i: ResultItem) -> Bool {
        i.matches(facets) && filter.matches(i, run.selection)
            && (search.isEmpty || i.name.localizedCaseInsensitiveContains(search) || (i.detail ?? "").localizedCaseInsensitiveContains(search))
    }
}

struct ItemRow: View {
    let item: ResultItem
    let run: ModuleRun
    var tint: Color = .accentColor
    var acceptsRisk = false
    /// The copy a duplicate or similar set keeps: badged, so it is never mistaken for one to delete.
    var kept = false
    let preview: ([URL]) -> Void
    @State private var showInfo = false
    @State private var hovering = false

    var body: some View {
        HStack {
            // A link or a note is not a choice: same room as a checkbox so the rows stay aligned.
            if item.isActionable {
                TriCheck(state: run.selection.contains(item.id) ? .on : .off, label: item.name, tint: tint, size: 18) { run.toggle(item) }
            } else {
                Color.clear.frame(width: 18, height: 18).accessibilityHidden(true)
            }
            if let url = item.url, Thumbnail.isImage(url) { Thumbnail(url: url, side: 40) }
            else if let s = item.symbol { Image(systemName: s).frame(width: 18) }
            else if let url = item.url { Image(nsImage: IconCache.icon(url.path)).resizable().frame(width: 18, height: 18) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                if let d = item.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            if kept {
                Text("À garder").font(.caption.weight(.semibold)).foregroundStyle(tint)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.15)))
            }
            Spacer()
            if let url = item.url, Thumbnail.isImage(url) {
                Button { preview([url]) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless).pointerStyle(.link).foregroundStyle(.secondary)
                    .help("Voir l'image (Coup d'œil)").accessibilityLabel("Voir \(item.name)")
            }
            if let date = item.date { Text(FileSizer.date(date, time: false)).font(.caption).foregroundStyle(.secondary) }
            if item.size > 0 { Text(FileSizer.format(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing) }
            if let link = item.openLink {
                Button("Ouvrir") { NSWorkspace.shared.open(link) }.buttonStyle(GlassButtonStyle(tint: tint))
                    .help(link.isFileURL ? "Ouvre \(link.deletingPathExtension().lastPathComponent)"
                          : link.scheme == "macappstore" ? "Ouvre les mises à jour de l'App Store" : "Ouvre Réglages Système")
            } else if acceptsRisk { riskControl }
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
        .popover(isPresented: $showInfo, arrowEdge: .trailing) { ItemInfo(item: item) }
        .contextMenu {
            if acceptsRisk {
                let accepted = RiskAcceptance.shared.contains(item.id)
                Button(accepted ? "Ne plus accepter ce risque" : "J'accepte ce risque") { run.acceptRisk([item.id], !accepted) }
                Divider()
            }
            if let url = item.url {
                Button("Coup d'œil") { preview([url]) }
                Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Ouvrir") { NSWorkspace.shared.open(url) }
                Button("Infos") { showInfo = true }
                Button("Copier le chemin") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                Divider()
                Button("Ajouter à la liste d'exclusion") { run.ignore(item) }
            }
        }
    }
}

extension ItemRow {
    /// Accepted: a "Risque accepté" mark, which undoes on click. Otherwise the offer shows under the pointer only.
    @ViewBuilder private var riskControl: some View {
        let accepted = RiskAcceptance.shared.contains(item.id)
        if accepted || hovering {
            Button { run.acceptRisk([item.id], !accepted) } label: {
                Label(accepted ? "Risque accepté" : "J'accepte ce risque", systemImage: accepted ? "checkmark.shield.fill" : "checkmark.shield")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, DS.Space.s).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(accepted ? 0.12 : 0.06)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).pointerStyle(.link)
            .foregroundStyle(.secondary)
            .help(accepted ? "Vous avez accepté ce risque : il ne compte plus dans la note de santé. Cliquez pour annuler."
                           : "L'élément restera listé à chaque analyse, mais ne comptera plus dans la note de santé.")
        }
    }
}

/// "Infos" popover: read from the file's resource values, nothing written.
struct ItemInfo: View {
    let item: ResultItem

    var body: some View {
        let v = item.url.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .localizedTypeDescriptionKey]) }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Nom", item.name)
            if let t = v?.localizedTypeDescription { row("Type", t) }
            row("Taille", item.size > 0 ? FileSizer.format(item.size) : "—")
            if let p = item.url?.path { row("Chemin", p) }
            row("Créé", v?.creationDate)
            row("Modifié", v?.contentModificationDate ?? item.date)
            row("Dernier accès", v?.contentAccessDate)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ date: Date?) -> some View {
        row(label, date.map { FileSizer.date($0) } ?? "—")
    }
}

struct TriCheck: View {
    let state: SelectionState
    /// What the box selects, read by VoiceOver.
    var label = "Sélection"
    /// Colour of a checked box: the module accent on the tiles and the review list.
    var tint: Color = .accentColor
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.circle.fill" : state == .mixed ? "minus.circle.fill" : "circle")
                .font(.system(size: size))
                .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "coché" : state == .mixed ? "partiellement coché" : "non coché")
    }
}

/// Results as tiles: one card per module in Vibe Check, one per category elsewhere.
/// One tile: a category, or a module in Vibe Check.
struct ResultTile: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let actionTitle: String
    /// Shown by the tile's info button.
    var info: String? = nil
    let items: [ResultItem]
    /// Items the tile's box ticks: the card's bulk items in Vibe Check, the category's own box elsewhere.
    var tick: [ResultItem] = []
    let report: ExecutionReport?
    var disabled = false
}

struct TilesView<Footer: View>: View {
    /// The selection in large and the total beside it. Nothing selected yet: what was found, and how to choose.
    /// Without sizes (threats, networks, permissions), counts instead of "Zéro ko".
    @ViewBuilder private var summary: some View {
        let found = run.allItems.count
        let picked = run.selectedItems.count
        let big = Font.system(size: 34, weight: .bold, design: .rounded).monospacedDigit()
        let gradient = LinearGradient(colors: [.white, Theme.accent(run.entry.id)], startPoint: .top, endPoint: .bottom)
        if picked == 0 {
            VStack(spacing: DS.Space.xs) {
                Text(countLabel(found, "élément trouvé", "éléments trouvés").capitalizedFirst).font(big).foregroundStyle(gradient)
                Text("Rien n'est sélectionné : cochez une carte, ou ouvrez-la avec « Revoir » pour choisir.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                let bySize = run.selectedSize > 0
                Text(bySize ? FileSizer.format(run.selectedSize) : "\(picked)").font(big).foregroundStyle(gradient)
                    .contentTransition(.numericText()).animation(.smooth, value: picked)
                Text(bySize ? "sélectionnés sur \(FileSizer.format(run.totalSize))" : "sélectionné\(picked > 1 ? "s" : "") sur \(countLabel(found, "élément", "éléments"))")
                    .font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    @Bindable var run: ModuleRun
    /// Height of the page: the tiles and the round button are centred in it, and scroll together when they don't fit.
    let height: CGFloat
    /// Runs a tile's own action on its checked items (through the review and "apps à quitter" flow), with the tile id.
    let clean: (Set<String>, String) -> Void
    @ViewBuilder let footer: () -> Footer
    @AppStorage(Prefs.vibeCheckDisabled) private var vibeCheckDisabled = ""

    typealias Tile = ResultTile

    var tiles: [Tile] {
        guard run.isVibeCheck else {
            return run.allGroups.map { Tile(id: $0.id, title: $0.title, symbol: $0.symbol, actionTitle: run.actionTitle(tile: $0.id), info: $0.subtitle,
                                            items: $0.allItems, tick: $0.tickItems, report: nil) }
        }
        let scanned = run.results.map { r in
            Tile(id: r.module.id, title: r.module.title, symbol: r.module.symbol, actionTitle: r.module.actionTitle, info: r.module.subtitle,
                 items: Array(Dictionary(r.groups.flatMap(\.allItems).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values),
                 tick: r.groups.flatMap(\.bulkItems), report: run.reports[r.module.id])
        }
        let off = Prefs.lines(Prefs.vibeCheckDisabled)
        let scannedIDs = Set(run.results.map(\.module.id))
        let disabled = run.entry.modules.filter { off.contains($0.id) && !scannedIDs.contains($0.id) }.map {
            Tile(id: $0.id, title: $0.title, symbol: $0.symbol, actionTitle: $0.actionTitle, info: $0.subtitle, items: [], report: nil, disabled: true)
        }
        return scanned + disabled
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                Group {
                    if run.isVibeCheck {
                        Text(run.allGroups.isEmpty ? "Rien à signaler : votre Mac est en ordre." : "Vos tâches sont prêtes. Voici ce que nous avons trouvé :")
                            .font(.title2.bold()).multilineTextAlignment(.center)
                    } else {
                        summary.accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .entrance(0)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: DS.Space.l, alignment: .top)], spacing: DS.Space.l) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
                        TileCard(tile: tile, run: run, clean: clean) {
                            vibeCheckDisabled = Prefs.lines(Prefs.vibeCheckDisabled).subtracting([tile.id]).sorted().joined(separator: "\n")
                        }
                        .entrance(i + 1)
                    }
                }
                // Room for the hover lift and the shadows.
                .padding(.horizontal, DS.Space.xxl).padding(.vertical, DS.Space.m)
                footer().padding(.top, DS.Space.s)
            }
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A result tile on glass: tinted icon, the selection in large, a three-state box, Revoir and the tile's own action.
/// Lifts slightly under the pointer.
struct TileCard: View {
    let tile: ResultTile
    @Bindable var run: ModuleRun
    let clean: (Set<String>, String) -> Void
    let enable: () -> Void
    @State private var showInfo = false

    var selected: [ResultItem] { tile.items.filter { $0.isActionable && run.selection.contains($0.id) } }
    /// Updates, links and notes only: read, never selected nor run.
    var readOnly: Bool { !tile.items.isEmpty && !tile.items.contains(where: \.isActionable) }
    /// Every app of the Mac: opened to pick apps one by one, never ticked nor run from the card.
    var oneByOne: Bool { !run.isVibeCheck && ResultQueries.oneByOneGroupIDs.contains(tile.id) }
    /// "57 apps installées", "149 fichiers en double"…
    var oneByOneCount: String {
        let g = run.allGroups.first { $0.id == tile.id }
        let sets = g?.groups.count ?? 0, files = g?.allItems.count ?? 0
        let text = switch tile.id {
        case "applications.all": countLabel(sets, "app installée", "apps installées")
        case "clutter.duplicates": countLabel(sets, "fichier en double", "fichiers en double")
        case "clutter.similar": countLabel(sets, "série d'images", "séries d'images")
        case "clutter.downloads": countLabel(files, "téléchargement", "téléchargements")
        default: countLabel(files, "fichier", "fichiers")
        }
        return text.capitalizedFirst
    }
    var state: SelectionState { ResultQueries.boxState(tick: tile.tick, all: tile.items, selection: run.selection) }

    var body: some View {
        let tint = Theme.accent(run.isVibeCheck ? tile.id : run.entry.id)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                TintedIcon(symbol: tile.symbol, tint: tint, size: 42)
                Spacer()
                if let info = tile.info {
                    Button { showInfo.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 15)) }
                        .buttonStyle(.borderless).pointerStyle(.link).foregroundStyle(.secondary)
                        .accessibilityLabel("À propos de « \(tile.title) »")
                        .help("À propos de « \(tile.title) »")
                        .popover(isPresented: $showInfo) { Text(info).padding(DS.Space.m).frame(width: 260) }
                }
                if !tile.items.isEmpty && !readOnly && !oneByOne {
                    TriCheck(state: state, label: tile.title, tint: tint, size: 19) {
                        run.selection = ResultQueries.toggling(tick: tile.tick, all: tile.items, selection: run.selection)
                    }
                }
            }
            Text(tile.title).font(.headline).lineLimit(1).padding(.top, DS.Space.xs)
            if tile.disabled {
                Label("Désactivée dans les réglages", systemImage: "slash.circle").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Activer", action: enable).help("Prend effet à la prochaine analyse").buttonStyle(GlassButtonStyle(tint: tint))
            } else if tile.items.isEmpty {
                if let r = tile.report {
                    Label(CardOutcomes.status(r).replacingOccurrences(of: "\n", with: " · "), systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Label("Rien à signaler", systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                Spacer(minLength: 0)
            } else if readOnly {
                let updates = tile.id == "applications.updates" || tile.id == "applications.macos"
                Text((updates ? countLabel(tile.items.count, "mise à jour", "mises à jour") : countLabel(tile.items.count, "élément", "éléments")).capitalizedFirst)
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                Label(updates ? "À installer depuis l'App Store, l'app ou Réglages Système" : "À consulter, rien à \(tile.actionTitle.lowercased())",
                      systemImage: updates ? "arrow.down.circle" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: DS.Space.xs)
                Button("Voir") { run.reviewing = tile.id }.buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
                    .help("Voir le détail")
            } else {
                // What was found, in large; the selection below it. "0 élément(s)" read as "nothing found".
                let foundSize = tile.items.reduce(0) { $0 + $1.size }
                let pickedSize = selected.reduce(0) { $0 + $1.size }
                let value = run.isVibeCheck && tile.id == "protection" ? countLabel(tile.items.count, "menace", "menaces")
                    : foundSize > 0 ? FileSizer.format(foundSize) : countLabel(tile.items.count, "élément", "éléments")
                Text(value.capitalizedFirst).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                // Risks the user already lives with, said on the card: no need to open it again at each scan.
                let accepted = tile.items.filter { RiskAcceptance.shared.contains($0.id) }.count
                if oneByOne {
                    // Picked inside, one by one: the card says how many there are, then what was picked.
                    Text(selected.isEmpty ? oneByOneCount : "\(selected.count) sélectionné\(selected.count > 1 ? "s" : "") · \(FileSizer.format(pickedSize))")
                        .font(.caption).foregroundStyle(selected.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                } else if accepted > 0 && accepted == tile.items.count && state == .off {
                    Label(accepted > 1 ? "Tous les risques sont acceptés" : "Risque accepté", systemImage: "checkmark.shield.fill")
                        .font(.caption).foregroundStyle(Theme.healthy)
                } else {
                    Label(selectionLine(pickedSize: pickedSize, foundSize: foundSize)
                            + (accepted > 0 ? " · \(accepted) risque\(accepted > 1 ? "s" : "") accepté\(accepted > 1 ? "s" : "")" : ""),
                          systemImage: state == .off ? "circle" : state == .on ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                        .font(.caption).foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.numericText()).animation(.smooth, value: selected.count)
                }
                Spacer(minLength: DS.Space.xs)
                if oneByOne {
                    Button("Voir") { run.reviewing = tile.id }.buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
                        .help("Choisir les apps à désinstaller une par une")
                } else {
                HStack(spacing: DS.Space.s) {
                    Button("Revoir") { run.reviewing = tile.id }.buttonStyle(GlassButtonStyle())
                        .help("Voir le détail et choisir les éléments un par un")
                    Button(tile.actionTitle) { clean(Set(tile.items.map(\.id)), tile.id) }.disabled(selected.isEmpty)
                        .buttonStyle(GlassButtonStyle(tint: tint, prominent: true))
                        .disabledHint(selected.isEmpty ? "Cochez la carte (en haut à droite) ou choisissez dans « Revoir » ce qu'il faut \(tile.actionTitle.lowercased())." : nil)
                }
                }
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .glass(tint: tile.disabled ? nil : tint, radius: DS.Radius.tile, interactive: !tile.disabled, selected: state != .off)
        .opacity(tile.disabled ? 0.65 : 1)
        .animation(DS.spring, value: state)
    }

    /// "Aucun sélectionné", "Tout est sélectionné", "2 sur 6 sélectionnés · 1,2 Go".
    private func selectionLine(pickedSize: Int64, foundSize: Int64) -> String {
        switch state {
        case .off: return "Aucun sélectionné"
        case .on: return "Tout est sélectionné"
        case .mixed:
            let n = selected.count
            return "\(n) sur \(tile.items.count) sélectionné\(n > 1 ? "s" : "")" + (foundSize > 0 ? " · \(FileSizer.format(pickedSize))" : "")
        }
    }
}

extension String {
    /// "aucun élément" → "Aucun élément".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// An app in a list: its real icon, name over version and vendor, last use and size. Taller than a file row.
struct AppRow<Check: View>: View {
    let group: ResultGroup
    let app: URL
    let check: Check

    var body: some View {
        let bundle = group.items.first { $0.id == app.path }
        HStack(spacing: DS.Space.m) {
            check
            Image(nsImage: IconCache.icon(app.path))
                .resizable().interpolation(.high).frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.body.weight(.semibold)).lineLimit(1)
                if let s = group.subtitle, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
            }
            .layoutPriority(1)
            Spacer(minLength: DS.Space.s)
            if let used = bundle?.date {
                Text(FileSizer.date(used, time: false)).font(.caption).foregroundStyle(.secondary)
                    .help("Dernière ouverture")
            }
            Text(group.totalSize > 0 ? FileSizer.format(group.totalSize) : "—")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, DS.Space.xs)
        // The list's disclosure chevron sits on the label's first baseline, i.e. level with the name: moving that
        // baseline to the middle of the row (plus the chevron's own baseline-to-centre offset) centres it.
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
        .accessibilityElement(children: .contain)
    }
}

/// Filters of a list (`ResultGroup.facetKeys`): the first as counted chips, the others as menus.
/// Counts are taken on the whole list, so a chip never reads 0 because of another filter.
struct FacetBar: View {
    let group: ResultGroup
    @Binding var facets: [String: String]
    let tint: Color

    var body: some View {
        let keys = group.facetKeys.filter { group.facetCounts($0).count > 1 }
        HStack(spacing: DS.Space.s) {
            if let first = keys.first {
                let values = ordered(group.facetCounts(first))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.xs) {
                        chip("Tout", count: values.reduce(0) { $0 + $1.1 }, on: facets[first] == nil) { facets[first] = nil }
                        ForEach(values, id: \.0) { name, n in
                            chip(name, count: n, on: facets[first] == name) { facets[first] = facets[first] == name ? nil : name }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            ForEach(keys.dropFirst(), id: \.self) { key in
                Picker(key, selection: Binding(get: { facets[key] ?? "" }, set: { facets[key] = $0.isEmpty ? nil : $0 })) {
                    Text("\(key) : tout").tag("")
                    Divider()
                    ForEach(ordered(group.facetCounts(key)), id: \.0) { name, n in Text("\(name) (\(n))").tag(name) }
                }
                .labelsHidden().fixedSize().help("Filtrer par \(key.lowercased())")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filtres")
    }

    /// The most common first; catch-all buckets ("Autres éditeurs", "Ailleurs"…) last.
    private func ordered(_ counts: [String: Int]) -> [(String, Int)] {
        let others: Set<String> = ["Autres éditeurs", "Internet et autres", "Ailleurs", "Autres"]
        return counts.sorted { (others.contains($0.key) ? 1 : 0, -$0.value, $0.key) < (others.contains($1.key) ? 1 : 0, -$1.value, $1.key) }
            .map { ($0.key, $0.value) }
    }

    private func chip(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .font(.callout.weight(on ? .semibold : .regular))
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
            .background(Capsule().fill(on ? AnyShapeStyle(tint.opacity(0.85)) : AnyShapeStyle(.white.opacity(0.08))))
            .overlay(Capsule().strokeBorder(.white.opacity(on ? 0.25 : 0.1)))
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityLabel("\(title), \(count) app\(count > 1 ? "s" : "")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A real preview of an image, made by Quick Look in the background; the file's icon until it is ready.
struct Thumbnail: View {
    let url: URL
    var side: CGFloat = 32
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale
    /// Thumbnails already made, so a row scrolled back into view does not ask Quick Look again.
    nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 500; return c }()

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: IconCache.icon(url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.12)))
        .accessibilityHidden(true)
        .task(id: url) {
            let key = "\(url.path)#\(side)" as NSString
            if let cached = Self.cache.object(forKey: key) { image = cached; return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                       representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                Self.cache.setObject(rep.nsImage, forKey: key)
                image = rep.nsImage
            }
        }
    }
}

/// File and app icons, asked of Launch Services once per path rather than at every row the list draws.
@MainActor enum IconCache {
    static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 2_000; return c }()

    static func icon(_ path: String) -> NSImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
