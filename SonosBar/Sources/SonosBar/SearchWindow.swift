import SwiftUI
import AppKit

// MARK: - Søgevindue

/// Eget vindue til at søge i musiktjenester og vælge, hvilket rum musikken skal spille i
@MainActor
enum SearchWindow {
    private static var window: NSWindow?

    static func show(model: SonosModel, services: ServiceModel) {
        closeMenu(except: window)
        if window == nil {
            let host = NSHostingController(rootView: SearchView().environmentObject(model).environmentObject(services))
            host.sizingOptions = []   // vinduets størrelse styres af brugeren, ikke af indholdet
            let w = NSWindow(contentViewController: host)
            w.title = String(localized: "Søg efter musik")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 820, height: 600))
            w.center()
            w.setFrameAutosaveName("SonosBarSearch")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Én linje i resultattabellen
struct SearchRow: Identifiable, Hashable {
    let id: String
    let item: ServiceItem
    let service: MusicService
    let typeKey: String
    let typeTitle: String
    let typeOrder: Int

    var title: String { item.title }
    var artist: String { item.artist }
    var album: String { item.album }
    var serviceName: String { service.name }

    static func == (a: SearchRow, b: SearchRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Hvad resultaterne kan grupperes efter
enum SearchGrouping: String, CaseIterable, Identifiable {
    case none, type, service, artist, album
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "Ingen gruppering")
        case .type: return String(localized: "Type")
        case .service: return String(localized: "Tjeneste")
        case .artist: return String(localized: "Kunstner")
        case .album: return String(localized: "Album")
        }
    }
}

/// Kolonner der kan sorteres efter – gemmes som tekst, så valget huskes
private enum SortKey: String {
    case title, artist, album, type, service

    var comparator: KeyPathComparator<SearchRow> {
        switch self {
        case .title: return KeyPathComparator(\SearchRow.title, comparator: .localizedStandard)
        case .artist: return KeyPathComparator(\SearchRow.artist, comparator: .localizedStandard)
        case .album: return KeyPathComparator(\SearchRow.album, comparator: .localizedStandard)
        case .type: return KeyPathComparator(\SearchRow.typeOrder)
        case .service: return KeyPathComparator(\SearchRow.serviceName, comparator: .localizedStandard)
        }
    }

    static func from(_ c: KeyPathComparator<SearchRow>) -> SortKey? {
        switch c.keyPath {
        case \SearchRow.title: return .title
        case \SearchRow.artist: return .artist
        case \SearchRow.album: return .album
        case \SearchRow.typeOrder: return .type
        case \SearchRow.serviceName: return .service
        default: return nil
        }
    }
}

struct SearchView: View {
    @EnvironmentObject var services: ServiceModel
    @EnvironmentObject var model: SonosModel
    @FocusState private var searchFocused: Bool

    // Visningen huskes fra gang til gang
    @AppStorage("searchTargetName") private var targetName = ""
    @AppStorage("search.filter") private var filterText = ""
    @AppStorage("search.grouping") private var grouping: SearchGrouping = .type
    @AppStorage("search.hiddenTypes") private var hiddenTypesRaw = ""
    @AppStorage("search.hiddenServices") private var hiddenServicesRaw = ""
    @AppStorage("search.sort") private var sortRaw = ""
    @AppStorage("search.columns") private var columnsData = Data()

    @State private var sortOrder: [KeyPathComparator<SearchRow>] = []
    @State private var columns = TableColumnCustomization<SearchRow>()
    @State private var selection = Set<SearchRow.ID>()

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if services.results.isEmpty {
                emptyState
            } else {
                filterBar
                Divider()
                table
                footer
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear {
            searchFocused = services.results.isEmpty
            ensureTarget()
            restoreViewSettings()
        }
        .onChange(of: model.groups) { ensureTarget() }
        .onChange(of: sortOrder) { saveSort() }
        .onChange(of: columns) { saveColumns() }
        .task { await services.prepare() }
    }

    // MARK: Søgning og rum

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField(prompt, text: $services.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { Task { await services.search() } }
            Button("Søg") { Task { await services.search() } }
                .disabled(services.query.trimmingCharacters(in: .whitespaces).isEmpty)
            if services.isSearching { ProgressView().controlSize(.small) }

            Divider().frame(height: 18)

            Picker("Afspil i", selection: $targetName) {
                ForEach(model.groups) { g in Text(verbatim: g.name).tag(g.name) }
            }
            .fixedSize()
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(services.message.isEmpty
                 ? String(localized: "Søg efter numre, albums, playlister og kunstnere.")
                 : services.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Filtre og gruppering

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filtrér i resultaterne", text: $filterText)
                    .textFieldStyle(.plain)
                if !filterText.isEmpty {
                    Button { filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.6)))
            .frame(maxWidth: 240)

            Menu {
                ForEach(allTypes, id: \.key) { t in
                    Toggle(t.title, isOn: typeBinding(t.key))
                }
                Divider()
                Button("Vis alle") { hiddenTypesRaw = "" }
            } label: {
                Label(typeMenuTitle, systemImage: "square.grid.2x2")
            }
            .fixedSize()

            Menu {
                ForEach(allServices) { svc in
                    Toggle(svc.name, isOn: serviceBinding(svc.id))
                }
                Divider()
                Button("Vis alle") { hiddenServicesRaw = "" }
            } label: {
                Label(serviceMenuTitle, systemImage: "music.note.house")
            }
            .fixedSize()

            Picker("Gruppér", selection: $grouping) {
                ForEach(SearchGrouping.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Spacer()

            Text("\(visibleRows.count) af \(services.rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Tabel

    private var table: some View {
        Table(of: SearchRow.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("") { row in
                Artwork(url: row.item.artURL, symbol: placeholder(row.item), size: 26)
            }
            .width(34)
            .customizationID("cover")
            .disabledCustomizationBehavior(.reorder)

            TableColumn("Titel", value: \.title) { row in
                Text(row.title).fontWeight(isPlaying(row) ? .semibold : .regular).help(row.title)
            }
            .width(min: 120, ideal: 180)
            .customizationID("title")

            TableColumn("Kunstner", value: \.artist) { row in Text(row.artist).help(row.artist) }
                .width(min: 80, ideal: 130)
                .customizationID("artist")

            TableColumn("Album", value: \.album) { row in Text(row.album).help(row.album) }
                .width(min: 80, ideal: 130)
                .customizationID("album")

            TableColumn("Type", value: \.typeOrder) { row in Text(row.typeTitle).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 90)
                .customizationID("type")

            TableColumn("Tjeneste", value: \.serviceName) { row in
                Text(verbatim: row.serviceName).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100)
            .customizationID("service")

            TableColumn("") { row in
                Button { play(row) } label: {
                    Image(systemName: isPlaying(row) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 17))
                }
                .buttonStyle(.borderless)
                .disabled(target == nil)
                .help(isPlaying(row) ? String(localized: "Pause")
                                     : target.map { String(localized: "Spil i \($0.name)") } ?? "")
            }
            .width(28)
            .customizationID("play")
            .disabledCustomizationBehavior(.all)
        } rows: {
            if grouping == .none {
                ForEach(visibleRows) { TableRow($0) }
            } else {
                ForEach(groupedRows, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.rows) { TableRow($0) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: SearchRow.ID.self) { ids in
            if let row = rowFor(ids.first) {
                Button(isPlaying(row) ? String(localized: "Pause")
                                      : String(localized: "Spil i \(target?.name ?? "")")) { play(row) }
                    .disabled(target == nil)
            }
        } primaryAction: { ids in
            // Dobbeltklik spiller
            if let row = rowFor(ids.first) { play(row) }
        }
    }

    @ViewBuilder private var footer: some View {
        let notes = services.results.filter { !$0.message.isEmpty }.map { "\($0.service.name): \($0.message)" }
        if !services.message.isEmpty || !notes.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                if !services.message.isEmpty { Text(services.message) }
                ForEach(notes, id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: Data

    private var hiddenTypes: Set<String> { Set(hiddenTypesRaw.split(separator: ",").map(String.init)) }
    private var hiddenServices: Set<Int> { Set(hiddenServicesRaw.split(separator: ",").compactMap { Int($0) }) }

    private var allTypes: [(key: String, title: String, order: Int)] {
        var seen = Set<String>()
        return services.rows
            .filter { seen.insert($0.typeKey).inserted }
            .map { ($0.typeKey, $0.typeTitle, $0.typeOrder) }
            .sorted { $0.order < $1.order }
    }

    private var allServices: [MusicService] {
        var seen = Set<Int>()
        return services.results.map(\.service).filter { seen.insert($0.id).inserted }
    }

    private var visibleRows: [SearchRow] {
        let f = filterText.trimmingCharacters(in: .whitespaces)
        let hidden = hiddenTypes, hiddenSvc = hiddenServices
        let rows = services.rows.filter { row in
            !hidden.contains(row.typeKey) && !hiddenSvc.contains(row.service.id)
                && (f.isEmpty || [row.title, row.artist, row.album].contains { $0.localizedCaseInsensitiveContains(f) })
        }
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    private var groupedRows: [(title: String, rows: [SearchRow])] {
        let rows = visibleRows
        let key: (SearchRow) -> String
        switch grouping {
        case .none, .type: key = { $0.typeTitle }
        case .service: key = { $0.serviceName }
        case .artist: key = { $0.artist.isEmpty ? String(localized: "Ukendt kunstner") : $0.artist }
        case .album: key = { $0.album.isEmpty ? String(localized: "Uden album") : $0.album }
        }
        var order: [String] = []
        var buckets: [String: [SearchRow]] = [:]
        for r in rows {
            let k = key(r)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(r)
        }
        if grouping == .type {
            order.sort { (buckets[$0]?.first?.typeOrder ?? 0) < (buckets[$1]?.first?.typeOrder ?? 0) }
        } else {
            order.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func rowFor(_ id: SearchRow.ID?) -> SearchRow? {
        guard let id else { return nil }
        return services.rows.first { $0.id == id }
    }

    private var typeMenuTitle: String {
        hiddenTypes.isEmpty ? String(localized: "Alle typer") : String(localized: "Udvalgte typer")
    }

    private var serviceMenuTitle: String {
        hiddenServices.isEmpty ? String(localized: "Alle tjenester") : String(localized: "Udvalgte tjenester")
    }

    private func typeBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { !hiddenTypes.contains(key) },
                set: { on in
                    var s = hiddenTypes
                    if on { s.remove(key) } else { s.insert(key) }
                    hiddenTypesRaw = s.sorted().joined(separator: ",")
                })
    }

    private func serviceBinding(_ id: Int) -> Binding<Bool> {
        Binding(get: { !hiddenServices.contains(id) },
                set: { on in
                    var s = hiddenServices
                    if on { s.remove(id) } else { s.insert(id) }
                    hiddenServicesRaw = s.sorted().map(String.init).joined(separator: ",")
                })
    }

    // MARK: Gemte visningsindstillinger

    private func restoreViewSettings() {
        // Sortering gemmes som fx "artist:asc"
        let parts = sortRaw.split(separator: ":").map(String.init)
        if parts.count == 2, let key = SortKey(rawValue: parts[0]) {
            var c = key.comparator
            c.order = parts[1] == "desc" ? .reverse : .forward
            sortOrder = [c]
        }
        if let saved = try? JSONDecoder().decode(TableColumnCustomization<SearchRow>.self, from: columnsData) {
            columns = saved
        }
    }

    private func saveSort() {
        guard let first = sortOrder.first, let key = SortKey.from(first) else { sortRaw = ""; return }
        sortRaw = "\(key.rawValue):\(first.order == .reverse ? "desc" : "asc")"
    }

    private func saveColumns() {
        if let data = try? JSONEncoder().encode(columns) { columnsData = data }
    }

    // MARK: Afspilning

    /// Rummet huskes på navnet, da Sonos' gruppe-id skifter, når der grupperes
    private var target: SonosGroup? {
        model.groups.first { $0.name == targetName } ?? model.groups.first
    }

    private func ensureTarget() {
        guard !model.groups.contains(where: { $0.name == targetName }) else { return }
        targetName = (model.groups.first { $0.state == .playing } ?? model.groups.first)?.name ?? ""
    }

    private func isPlaying(_ row: SearchRow) -> Bool {
        services.isPlaying(row.item, from: row.service, in: target)
    }

    private func play(_ row: SearchRow) {
        guard let g = target else { return }
        Task { await services.togglePlay(row.item, from: row.service, in: g) }
    }

    private func placeholder(_ item: ServiceItem) -> String? {
        switch item.kind {
        case .artist: return "person.fill"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        default: return nil
        }
    }

    private var prompt: String {
        let names = ListFormatter.localizedString(byJoining: services.searchable.map(\.name))
        return names.isEmpty ? String(localized: "Søg") : String(localized: "Søg i \(names)")
    }
}
