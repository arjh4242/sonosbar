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
            let w = NSWindow(contentViewController: host)
            w.title = String(localized: "Søg efter musik")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 480, height: 580))
            w.center()
            w.setFrameAutosaveName("SonosBarSearch")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SearchView: View {
    @EnvironmentObject var services: ServiceModel
    @EnvironmentObject var model: SonosModel
    @AppStorage("searchTargetName") private var targetName = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField(prompt, text: $services.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onSubmit { Task { await services.search() } }
                    Button("Søg") { Task { await services.search() } }
                        .disabled(services.query.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack(spacing: 8) {
                    Picker("Afspil i", selection: $targetName) {
                        ForEach(model.groups) { g in Text(verbatim: g.name).tag(g.name) }
                    }
                    .fixedSize()
                    Spacer()
                    if services.isSearching { ProgressView().controlSize(.small) }
                }
            }
            .padding(12)

            Divider()

            if services.results.isEmpty {
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
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(services.results) { group in
                            ServiceResultsView(group: group, target: target)
                        }
                    }
                    .padding(12)
                }
                if !services.message.isEmpty {
                    Divider()
                    Text(services.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 380)
        .onAppear {
            searchFocused = true
            ensureTarget()
        }
        .onChange(of: model.groups) { _ in ensureTarget() }
        .task { await services.prepare() }
    }

    /// Rummet huskes på navnet, da Sonos' gruppe-id skifter, når der grupperes
    private var target: SonosGroup? {
        model.groups.first { $0.name == targetName } ?? model.groups.first
    }

    private func ensureTarget() {
        guard !model.groups.contains(where: { $0.name == targetName }) else { return }
        targetName = (model.groups.first { $0.state == .playing } ?? model.groups.first)?.name ?? ""
    }

    private var prompt: String {
        let names = ListFormatter.localizedString(byJoining: services.searchable.map(\.name))
        return names.isEmpty ? String(localized: "Søg") : String(localized: "Søg i \(names)")
    }
}

/// Resultaterne fra én tjeneste med dens navn som overskrift
struct ServiceResultsView: View {
    @EnvironmentObject var services: ServiceModel
    let group: ServiceResults
    let target: SonosGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.house.fill").foregroundStyle(.secondary)
                Text(verbatim: group.service.name).font(.headline)
            }
            if !group.message.isEmpty {
                Text(group.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(group.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(section.items) { item in
                        ServiceResultRow(item: item, target: target,
                                         isPlaying: services.isPlaying(item, from: group.service, in: target)) {
                            guard let g = target else { return }
                            Task { await services.togglePlay(item, from: group.service, in: g) }
                        }
                    }
                }
            }
        }
    }
}

/// Et søgeresultat. Klik på ▶︎ eller dobbeltklik på linjen for at spille det i det valgte rum.
struct ServiceResultRow: View {
    let item: ServiceItem
    let target: SonosGroup?
    let isPlaying: Bool
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: item.artURL, symbol: placeholder, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: play) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.borderless)
            .disabled(target == nil)
            .help(isPlaying ? String(localized: "Pause")
                            : target.map { String(localized: "Spil i \($0.name)") } ?? "")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
    }

    private var placeholder: String? {
        switch item.kind {
        case .artist: return "person.fill"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .station: return "dot.radiowaves.left.and.right"
        default: return nil
        }
    }
}
