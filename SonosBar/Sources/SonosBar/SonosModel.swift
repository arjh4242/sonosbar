import Foundation
import AppKit

enum PlayState: Equatable {
    case playing, paused, stopped, transitioning, unknown

    init(_ raw: String) {
        switch raw {
        case "PLAYING": self = .playing
        case "PAUSED_PLAYBACK": self = .paused
        case "STOPPED": self = .stopped
        case "TRANSITIONING": self = .transitioning
        default: self = .unknown
        }
    }
}

struct NowPlaying: Equatable {
    let title: String
    let artist: String
    let album: String
    let artURL: URL?
    /// SF Symbol der vises i stedet for et cover (fx TV)
    var symbol: String? = nil
}

/// En favorit eller Sonos-playliste
struct LibraryItem: Identifiable, Equatable {
    let id: String
    let title: String
    let uri: String
    let metadata: String
    let artURL: URL?
    /// Playlister, albums o.l. skal i køen; radio kan afspilles direkte
    let isContainer: Bool
}

/// En indgang der kan afspilles (TV eller line-in)
struct InputSource: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let uri: String
}

struct GroupMember: Equatable {
    let uuid: String
    let ip: String
    let name: String
}

struct SonosGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinatorIP: String
    var state: PlayState
    var coordinatorUUID = ""
    var members: [GroupMember] = []
    var volume: Int? = nil
    var muted = false
    var track: NowPlaying? = nil
    /// Tilladte handlinger for den nuværende kilde (tom = ukendt endnu)
    var actions: Set<String> = []

    var canNext: Bool { actions.contains("Next") }
    var canPrevious: Bool { actions.contains("Previous") }
}

@MainActor
final class SonosModel: ObservableObject {
    @Published var groups: [SonosGroup] = []
    @Published var status = ""
    @Published var isRefreshing = false
    @Published var favorites: [LibraryItem] = []
    @Published var playlists: [LibraryItem] = []
    /// Små ikoner til menuen (menupunkter kan ikke hente billeder selv)
    @Published var icons: [String: NSImage] = [:]
    /// Indgange pr. højttaler (UUID), hentes én gang
    @Published private var inputCaps: [String: (tv: Bool, lineIn: Bool)] = [:]
    @Published var manualIP: String = UserDefaults.standard.string(forKey: "manualIP") ?? ""

    var anyPlaying: Bool { groups.contains { $0.state == .playing } }

    /// Sættes af vinduet – mens det er åbent, opdateres oftere
    var isOpen = false

    private var knownIPs: [String] = []
    private var pollTask: Task<Void, Never>?
    private var volumeTasks: [String: Task<Void, Never>] = [:]
    private var lastVolumeChange: [String: Date] = [:]

    init() {
        // Find højttalerne med det samme ved opstart – ikke først når menuen åbnes
        Task { [weak self] in await self?.discoverAtStartup() }

        // Hold afspilningsstatus (og menulinje-ikonet) opdateret i baggrunden
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let open = self?.isOpen ?? false
                try? await Task.sleep(nanoseconds: open ? 3_000_000_000 : 10_000_000_000)
                await self?.updateStates()
            }
        }
    }

    func saveManualIP() {
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        manualIP = ip
        UserDefaults.standard.set(ip, forKey: "manualIP")
    }

    // MARK: - Opdatering

    /// Netværket er ofte ikke klar lige efter login – prøv op til 5 gange med 5 sekunders mellemrum
    private func discoverAtStartup() async {
        let attempts = 5
        for attempt in 1...attempts {
            // Er menuen allerede i gang med at søge, så vent på den
            while isRefreshing { try? await Task.sleep(nanoseconds: 200_000_000) }
            if groups.isEmpty { await refresh() }
            if !groups.isEmpty { return }
            guard attempt < attempts else { return } // refresh() har sat "Fandt ingen…"
            status = String(localized: "Fandt ingen Sonos-højttalere. Prøver igen om 5 sekunder (forsøg \(attempt) af \(attempts))…")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 1) Prøv kendte/manuelle IP'er først (hurtigt)
        var candidates: [String] = []
        let manual = manualIP.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty { candidates.append(manual) }
        candidates += knownIPs.filter { $0 != manual }

        var found = await loadTopology(from: candidates)

        // 2) Ellers: søg på netværket
        if found == nil {
            if groups.isEmpty { status = String(localized: "Søger efter Sonos-højttalere…") }
            let discovered = await Task.detached { SSDP.discover() }.value
            found = await loadTopology(from: discovered)
        }

        guard let newGroups = found else {
            groups = []
            status = String(localized: "Fandt ingen Sonos-højttalere. Tjek at Mac'en er på samme netværk, eller angiv en højttaler-IP under Indstillinger.")
            return
        }

        knownIPs = newGroups.map(\.coordinatorIP)
        // Bevar kendt status, så knapperne ikke blinker
        let old = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        groups = newGroups.map { g in
            var g = g
            if let o = old[g.id] {
                g.state = o.state; g.volume = o.volume; g.muted = o.muted; g.track = o.track
                g.actions = o.actions
            }
            return g
        }
        status = ""
        await updateStates()
        await loadLibrary()
    }

    // MARK: - Favoritter, playlister og indgange

    /// Favoritter og playlister gælder hele husstanden, så én højttaler er nok at spørge
    func loadLibrary() async {
        guard let ip = groups.first?.coordinatorIP else { return }
        async let fav = try? SonosClient.favorites(ip)
        async let pl = try? SonosClient.playlists(ip)
        if let f = await fav { favorites = f }
        if let p = await pl { playlists = p }
        await loadIcons(for: favorites + playlists)

        let unknown = groups.flatMap(\.members).filter { inputCaps[$0.uuid] == nil }
        for m in unknown {
            if let caps = try? await SonosClient.inputs(m.ip) { inputCaps[m.uuid] = caps }
        }
    }

    private func loadIcons(for items: [LibraryItem]) async {
        let missing = items.filter { icons[$0.id] == nil && $0.artURL != nil }
        let loaded = await withTaskGroup(of: (String, Data?).self) { tg in
            for item in missing {
                tg.addTask {
                    guard let url = item.artURL else { return (item.id, nil) }
                    return (item.id, try? await URLSession.shared.data(from: url).0)
                }
            }
            var out: [String: Data] = [:]
            for await (id, data) in tg { if let data { out[id] = data } }
            return out
        }
        for (id, data) in loaded {
            if let img = NSImage(data: data) { icons[id] = Self.menuIcon(from: img) }
        }
    }

    /// Kvadratisk udsnit med runde hjørner i menuikon-størrelse
    private static func menuIcon(from image: NSImage, side: CGFloat = 20) -> NSImage {
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            let s = image.size
            let scale = max(side / max(s.width, 1), side / max(s.height, 1))
            let w = s.width * scale, h = s.height * scale
            image.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            return true
        }
    }

    // MARK: - Gruppering

    /// Alle synlige højttalere i huset, sorteret efter navn
    var allSpeakers: [GroupMember] {
        var seen = Set<String>()
        return groups.flatMap(\.members)
            .filter { seen.insert($0.uuid).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setMember(_ m: GroupMember, in g: SonosGroup, included: Bool) async {
        await regroup {
            if included {
                try await SonosClient.join(m.ip, coordinatorUUID: g.coordinatorUUID)
            } else {
                try await SonosClient.leaveGroup(m.ip)
            }
        }
    }

    func addAllSpeakers(to g: SonosGroup) async {
        let others = allSpeakers.filter { s in !g.members.contains { $0.uuid == s.uuid } }
        await regroup {
            for m in others { try await SonosClient.join(m.ip, coordinatorUUID: g.coordinatorUUID) }
        }
    }

    func ungroup(_ g: SonosGroup) async {
        let others = g.members.filter { $0.uuid != g.coordinatorUUID }
        await regroup {
            for m in others { try await SonosClient.leaveGroup(m.ip) }
        }
    }

    private func regroup(_ change: () async throws -> Void) async {
        do {
            try await change()
            status = ""
        } catch {
            status = String(localized: "Kunne ikke ændre grupperingen. Prøv at opdatere.")
        }
        // Sonos skal lige nå at opdatere topologien
        try? await Task.sleep(nanoseconds: 700_000_000)
        await refresh()
    }

    /// Indgange der kan vælges i en gruppe. TV kan kun spilles af den højttaler, TV'et sidder i.
    func sources(for g: SonosGroup) -> [InputSource] {
        var out: [InputSource] = []
        if inputCaps[g.coordinatorUUID]?.tv == true {
            out.append(InputSource(id: "tv-\(g.coordinatorUUID)", name: String(localized: "TV"),
                                   symbol: "tv", uri: "x-sonos-htastream:\(g.coordinatorUUID):spdif"))
        }
        let allMembers = groups.flatMap(\.members)
        for m in allMembers where inputCaps[m.uuid]?.lineIn == true {
            out.append(InputSource(id: "line-\(m.uuid)", name: String(localized: "Line-in (\(m.name))"),
                                   symbol: "cable.connector", uri: "x-rincon-stream:\(m.uuid)"))
        }
        return out
    }

    func play(_ item: LibraryItem, in g: SonosGroup) async {
        setState(g.id, .playing) // optimistisk
        await run(g) {
            try await SonosClient.play(item, coordinatorIP: g.coordinatorIP, coordinatorUUID: g.coordinatorUUID)
        }
    }

    func play(_ source: InputSource, in g: SonosGroup) async {
        setState(g.id, .playing)
        await run(g) { try await SonosClient.play(uri: source.uri, coordinatorIP: g.coordinatorIP) }
    }

    private func loadTopology(from ips: [String]) async -> [SonosGroup]? {
        for ip in ips {
            if let g = try? await SonosClient.groups(via: ip), !g.isEmpty { return g }
        }
        return nil
    }

    private struct Snapshot: Sendable {
        var state: PlayState
        var volume: Int?
        var muted: Bool?
        var track: NowPlaying?
        var trackOK: Bool
        var actions: Set<String>?
    }

    func updateStates() async {
        let current = groups
        guard !current.isEmpty else { return }
        let snaps = await withTaskGroup(of: (String, Snapshot).self) { tg in
            for g in current {
                tg.addTask {
                    let ip = g.coordinatorIP
                    async let s = try? SonosClient.transportState(ip)
                    async let v = try? SonosClient.groupVolume(ip)
                    async let m = try? SonosClient.groupMute(ip)
                    async let a = try? SonosClient.transportActions(ip)
                    // nil betyder "intet spiller"; en fejl betyder "behold det vi har"
                    var track: NowPlaying?
                    var trackOK = true
                    do { track = try await SonosClient.nowPlaying(ip) } catch { trackOK = false }
                    return (g.id, Snapshot(state: await s ?? .unknown, volume: await v, muted: await m,
                                           track: track, trackOK: trackOK, actions: await a))
                }
            }
            var out: [String: Snapshot] = [:]
            for await (id, s) in tg { out[id] = s }
            return out
        }
        for i in groups.indices {
            let id = groups[i].id
            guard let s = snaps[id] else { continue }
            if s.state != .unknown { groups[i].state = s.state }
            // Overskriv ikke slideren mens brugeren trækker i den
            let recentlyChanged = lastVolumeChange[id].map { Date().timeIntervalSince($0) < 2 } ?? false
            if let v = s.volume, !recentlyChanged { groups[i].volume = v }
            if let m = s.muted { groups[i].muted = m }
            if s.trackOK { groups[i].track = s.track }
            if let a = s.actions { groups[i].actions = a }
        }
    }

    // MARK: - Kommandoer

    func toggle(_ g: SonosGroup) async {
        let wasPlaying = g.state == .playing
        setState(g.id, wasPlaying ? .paused : .playing) // optimistisk
        await run(g) {
            // Radio kan ikke pauses, kun stoppes
            if wasPlaying && !g.actions.contains("Pause") && g.actions.contains("Stop") {
                try await SonosClient.stop(g.coordinatorIP)
            } else if wasPlaying { try await SonosClient.pause(g.coordinatorIP) }
            else { try await SonosClient.play(g.coordinatorIP) }
        }
    }

    func next(_ g: SonosGroup) async {
        await run(g) { try await SonosClient.next(g.coordinatorIP) }
    }

    func previous(_ g: SonosGroup) async {
        await run(g) { try await SonosClient.previous(g.coordinatorIP) }
    }

    func setVolume(_ g: SonosGroup, _ volume: Int) {
        guard let i = groups.firstIndex(where: { $0.id == g.id }) else { return }
        groups[i].volume = volume
        let now = Date()
        // Nyt snapshot kun i starten af en "trækning", ellers går forholdet mellem højttalerne tabt
        let snapshot = lastVolumeChange[g.id].map { now.timeIntervalSince($0) > 2 } ?? true
        lastVolumeChange[g.id] = now

        volumeTasks[g.id]?.cancel()
        volumeTasks[g.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000) // debounce
            guard !Task.isCancelled else { return }
            do {
                try await SonosClient.setGroupVolume(g.coordinatorIP, volume, snapshot: snapshot)
            } catch {
                self?.status = String(localized: "Kunne ikke ændre lydstyrken i \(g.name).")
            }
        }
    }

    func toggleMute(_ g: SonosGroup) async {
        let newValue = !g.muted
        if let i = groups.firstIndex(where: { $0.id == g.id }) { groups[i].muted = newValue }
        do {
            try await SonosClient.setGroupMute(g.coordinatorIP, newValue)
        } catch {
            status = String(localized: "Kunne ikke slå lyden fra/til i \(g.name).")
        }
    }

    private func run(_ g: SonosGroup, _ action: () async throws -> Void) async {
        do {
            try await action()
            status = ""
        } catch let SonosError.upnp(code) where code == 701 || code == 711 {
            status = String(localized: "Den nuværende kilde i \(g.name) understøtter ikke den handling (fx radio).")
        } catch {
            status = String(localized: "Kunne ikke styre \(g.name). Prøv at opdatere.")
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let s = try? await SonosClient.transportState(g.coordinatorIP) {
            setState(g.id, s)
        }
        if let a = try? await SonosClient.transportActions(g.coordinatorIP),
           let i = groups.firstIndex(where: { $0.id == g.id }) {
            groups[i].actions = a
        }
        // Nyt nummer efter næste/forrige
        if let t = try? await SonosClient.nowPlaying(g.coordinatorIP),
           let i = groups.firstIndex(where: { $0.id == g.id }) {
            groups[i].track = t
        }
    }

    private func setState(_ id: String, _ s: PlayState) {
        if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].state = s }
    }
}
