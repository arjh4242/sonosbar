import SwiftUI
import AppKit
import ServiceManagement

@main
struct SonosBarApp: App {
    @StateObject private var model: SonosModel
    @StateObject private var services: ServiceModel

    init() {
        let m = SonosModel()
        let s = ServiceModel(sonos: m)
        m.artworkResolver = { [weak s] uri in await s?.artwork(forTrackURI: uri) }
        _model = StateObject(wrappedValue: m)
        _services = StateObject(wrappedValue: s)
        // Ingen ikon i Dock – kun i menulinjen
        NSApplication.shared.setActivationPolicy(.accessory)
        AppAppearance.current.apply()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model).environmentObject(services)
        } label: {
            Image(systemName: model.anyPlaying ? "hifispeaker.fill" : "hifispeaker")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Tema og sprog

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light: return "Lys"
        case .dark: return "Mørk"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, da, en
    var id: String { rawValue }

    static var current: AppLanguage {
        let langs = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        let explicit = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil
        guard explicit, let first = langs.first else { return .system }
        return first.hasPrefix("en") ? .en : first.hasPrefix("da") ? .da : .system
    }

    /// Sprognavne vises altid på deres eget sprog
    var label: Text {
        switch self {
        case .system: return Text("System")
        case .da: return Text(verbatim: "Dansk")
        case .en: return Text(verbatim: "English")
        }
    }

    /// Gemmer valget og genstarter appen, så alle tekster skifter sprog
    func applyAndRelaunch() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: SonosModel
    @EnvironmentObject var services: ServiceModel
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sonos").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Opdater")
                if !services.searchable.isEmpty {
                    Button { SearchWindow.show(model: model, services: services) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Søg efter musik")
                }
                Button { SettingsWindow.show(model: model, services: services) } label: {
                    Image(systemName: "gearshape")
                }
                .help("Indstillinger")
            }
            .buttonStyle(.borderless)

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.groups) { g in
                GroupCard(group: g)
                if g.id != model.groups.last?.id { Divider() }
            }

            Divider()

            Button("Afslut SonosBar") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(12)
        .frame(width: 320)
        .background(WindowReader(window: $window))
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size) { _, size in fit(window, to: size) }
        })
        .task {
            await model.refresh()
            await services.prepare()
        }
        .onAppear { model.isOpen = true }
        .onDisappear { model.isOpen = false }
    }
}

/// Menulinje-vinduet følger ikke selv med, når indholdet skifter højde (fx når rum
/// grupperes), og efterlader en "spøgelsesramme". Tilpas det selv med toppen fast.
@MainActor
private func fit(_ window: NSWindow?, to size: CGSize) {
    DispatchQueue.main.async {
        guard let w = window, size.height > 0 else { return }
        let current = w.contentRect(forFrameRect: w.frame).size
        if abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 {
            var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
            w.setFrame(frame, display: true)
        }
        w.invalidateShadow()
        w.contentView?.needsDisplay = true
        w.displayIfNeeded()
    }
}

/// Giver adgang til det NSWindow, en SwiftUI-visning ligger i
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { window = v.window }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

// MARK: - Indstillinger

/// Luk menuen – den er nøglevinduet, når der klikkes på en knap i den
/// (SwiftUI's menuvindue hedder internt noget med "MenuBarExtra")
@MainActor
func closeMenu(except keep: NSWindow?) {
    for w in NSApp.windows where w !== keep
        && (w === NSApp.keyWindow || String(describing: type(of: w)).contains("MenuBarExtra")) {
        w.close()
    }
}

/// Eget vindue til indstillingerne, så menuen holdes ren
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: SonosModel, services: ServiceModel) {
        closeMenu(except: window)

        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model).environmentObject(services))
            let w = NSWindow(contentViewController: host)
            w.title = String(localized: "Indstillinger")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Menulinje-apps er ikke aktive af sig selv – uden dette havner vinduet bagved
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: SonosModel
    @EnvironmentObject var services: ServiceModel
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @State private var language: AppLanguage = .current
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginFailed = false

    var body: some View {
        Form {
            Section("Generelt") {
                Picker("Udseende", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, value in value.apply() }

                Picker("Sprog", selection: $language) {
                    ForEach(AppLanguage.allCases) { $0.label.tag($0) }
                }
                .onChange(of: language) { _, value in value.applyAndRelaunch() }

                Toggle("Start ved login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if loginFailed {
                    Text("Kunne ikke ændre start ved login. Ligger appen i Programmer-mappen?")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            ServiceSettingsSection()

            Section {
                TextField("Højttaler-IP (valgfri)", text: $model.manualIP,
                          prompt: Text(verbatim: "192.168.1.20"))
                    .onChange(of: model.manualIP) { model.saveManualIP() }
                    .onSubmit { Task { await model.refresh() } }
            } header: {
                Text("Forbindelse")
            } footer: {
                Text("Kun nødvendigt hvis automatisk søgning ikke finder dine højttalere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
        .task { await services.prepare() }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginFailed = false
        } catch {
            loginFailed = true
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct GroupCard: View {
    @EnvironmentObject var model: SonosModel
    let group: SonosGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Artwork(url: group.track?.artURL, symbol: group.track?.symbol)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(group.track?.title ?? String(localized: "Intet afspilles"))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .help(helpText)

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    GroupPicker(group: group)
                    PlayPicker(group: group)

                    // Næste/forrige vises kun når kilden tillader det (ikke fx radio og TV)
                    if group.canPrevious {
                        Button { Task { await model.previous(group) } } label: {
                            Image(systemName: "backward.fill")
                        }
                    }
                    Button { Task { await model.toggle(group) } } label: {
                        Image(systemName: group.state == .playing ? "pause.fill" : "play.fill")
                            .frame(width: 16)
                    }
                    if group.canNext {
                        Button { Task { await model.next(group) } } label: {
                            Image(systemName: "forward.fill")
                        }
                    }
                }
                .font(.system(size: 14))
            }

            HStack(spacing: 8) {
                Button { Task { await model.toggleMute(group) } } label: {
                    Image(systemName: speakerIcon).frame(width: 18)
                }
                .help(group.muted ? Text("Slå lyd til") : Text("Slå lyd fra"))

                Slider(value: volumeBinding, in: 0...100)
                    .controlSize(.small)
                    .disabled(group.volume == nil)

                Text(group.volume.map(String.init) ?? "–")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

                // Grupper kan foldes ud, så hver højttaler kan skrues for sig
                if group.members.count > 1 {
                    Button { model.toggleExpanded(group) } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 14)
                    }
                    .help(expanded ? Text("Skjul højttalere") : Text("Vis lydstyrke for hver højttaler"))
                }
            }

            if expanded {
                VStack(spacing: 4) {
                    ForEach(group.members, id: \.uuid) { m in
                        HStack(spacing: 8) {
                            Text(verbatim: m.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 92, alignment: .leading)
                            Slider(value: speakerBinding(m), in: 0...100)
                                .controlSize(.mini)
                                .disabled(model.speakerVolumes[m.uuid] == nil)
                            Text(model.speakerVolumes[m.uuid].map(String.init) ?? "–")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                        }
                    }
                }
                .padding(.leading, 26)
                .padding(.trailing, 22)
            }
        }
        .buttonStyle(.borderless)
    }

    private var subtitle: String? {
        guard let t = group.track else { return nil }
        return [t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var helpText: String {
        guard let t = group.track else { return group.name }
        return [t.title, t.artist, t.album].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var speakerIcon: String {
        if group.muted || group.volume == 0 { return "speaker.slash.fill" }
        switch group.volume ?? 0 {
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private var expanded: Bool { group.members.count > 1 && model.expandedGroups.contains(group.id) }

    private func speakerBinding(_ m: GroupMember) -> Binding<Double> {
        Binding(
            get: { Double(model.speakerVolumes[m.uuid] ?? 0) },
            set: { model.setSpeakerVolume(m, in: group, Int($0.rounded())) }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(group.volume ?? 0) },
            set: { model.setVolume(group, Int($0.rounded())) }
        )
    }
}

/// Vælg hvilke højttalere der spiller sammen med et rum
struct GroupPicker: View {
    @EnvironmentObject var model: SonosModel
    let group: SonosGroup

    var body: some View {
        Menu {
            Section("Spil sammen med \(group.name)") {
                ForEach(model.allSpeakers, id: \.uuid) { m in
                    Toggle(m.name, isOn: binding(for: m))
                        // Rummets egen højttaler kan ikke fjernes, når den er alene
                        .disabled(isMember(m) && group.members.count == 1)
                }
            }
            Divider()
            Button("Tilføj alle") { Task { await model.addAllSpeakers(to: group) } }
                .disabled(group.members.count == model.allSpeakers.count)
            Button("Opløs gruppe") { Task { await model.ungroup(group) } }
                .disabled(group.members.count < 2)
        } label: {
            Image(systemName: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Gruppér højttalere")
    }

    private func isMember(_ m: GroupMember) -> Bool {
        group.members.contains { $0.uuid == m.uuid }
    }

    private func binding(for m: GroupMember) -> Binding<Bool> {
        Binding(
            get: { isMember(m) },
            set: { on in Task { await model.setMember(m, in: group, included: on) } }
        )
    }
}

/// Vælg hvad der skal spilles i et rum – som "Mit Sonos" i Sonos-appen
struct PlayPicker: View {
    @EnvironmentObject var model: SonosModel
    let group: SonosGroup

    var body: some View {
        Menu {
            Section("Favoritter") {
                if model.favorites.isEmpty {
                    Text("Ingen favoritter – tilføj dem i Sonos-appen")
                }
                ForEach(model.favorites) { item in
                    Button { Task { await model.play(item, in: group) } } label: {
                        Label { Text(item.title) } icon: { icon(for: item) }
                    }
                }
            }
            if !model.playlists.isEmpty {
                Section("Playlister") {
                    ForEach(model.playlists) { item in
                        Button { Task { await model.play(item, in: group) } } label: {
                            Label { Text(item.title) } icon: { icon(for: item) }
                        }
                    }
                }
            }
            let sources = model.sources(for: group)
            if !sources.isEmpty {
                Section("Kilder") {
                    ForEach(sources) { src in
                        Button { Task { await model.play(src, in: group) } } label: {
                            Label(src.name, systemImage: src.symbol)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "music.note.list")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Vælg hvad der skal spilles")
    }

    /// Cover hvis det findes, ellers et ikon efter typen
    @ViewBuilder private func icon(for item: LibraryItem) -> some View {
        if let img = model.icons[item.id] {
            Image(nsImage: img)
        } else {
            Image(systemName: item.isContainer ? "music.note.list" : "radio")
        }
    }
}

struct Artwork: View {
    let url: URL?
    var symbol: String? = nil
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            Image(systemName: symbol ?? "music.note")
                .font(.system(size: (symbol == nil ? 13 : 20) * size / 44))
                .foregroundStyle(.secondary)
            if let url {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Musiktjenester

/// Log på og af musiktjenester (Indstillinger)
struct ServiceSettingsSection: View {
    @EnvironmentObject var services: ServiceModel

    var body: some View {
        Section {
            ForEach(services.loggedIn) { svc in
                HStack {
                    Text(verbatim: svc.name)
                    Spacer()
                    Button("Log af") { services.logout(svc) }
                }
            }

            if services.loginServiceID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(services.loginMessage).font(.callout)
                    Spacer()
                    Button("Annullér") { services.cancelLogin() }
                }
            } else {
                let notLoggedIn = services.available.filter { !services.loggedIn.contains($0) }
                Menu("Log på en tjeneste …") {
                    ForEach(notLoggedIn) { svc in
                        Button(svc.name) { services.login(svc) }
                    }
                }
                .disabled(notLoggedIn.isEmpty)
                if !services.loginMessage.isEmpty {
                    Text(services.loginMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Musiktjenester")
        } footer: {
            Text("Log på for at kunne søge i tjenesten fra menuen. Der åbnes en side i din browser, hvor du logger ind. Musikken afspilles med den konto, der er tilknyttet i Sonos-appen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            ForEach(services.enabledAnonymous) { svc in
                HStack {
                    Text(verbatim: svc.name)
                    Spacer()
                    Button("Fjern") { services.setEnabled(svc, false) }
                }
            }
            let others = services.anonymous.filter { !services.enabledAnonymous.contains($0) }
            Menu("Tilføj tjeneste uden login …") {
                ForEach(others) { svc in
                    Button(svc.name) { services.setEnabled(svc, true) }
                }
            }
            .disabled(others.isEmpty)
        } header: {
            Text("Tjenester uden login")
        } footer: {
            Text("Fx DR LYD og TuneIn. De søges i uden login. Tjenester, du har favoritter fra, kommer automatisk med.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
