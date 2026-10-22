import Foundation
import AppKit

struct SearchSection: Identifiable {
    let id: String
    let title: String
    let items: [ServiceItem]
}

/// Søgeresultater fra én tjeneste
struct ServiceResults: Identifiable {
    let service: MusicService
    let sections: [SearchSection]
    let message: String
    var id: Int { service.id }
}

/// Login, søgning og afspilning fra musiktjenester som Telmore Musik og Spotify
@MainActor
final class ServiceModel: ObservableObject {
    /// Tjenester med browser-login
    @Published var available: [MusicService] = []
    @Published var loggedIn: [MusicService] = []
    /// Tjenester uden login (fx DR LYD, TuneIn) – og dem, der er med i søgningen
    @Published var anonymous: [MusicService] = []
    @Published var enabledAnonymous: [MusicService] = []

    /// Alt, der søges i
    var searchable: [MusicService] { loggedIn + enabledAnonymous }
    @Published var query = ""
    @Published var results: [ServiceResults] = []
    @Published var isSearching = false
    @Published var message = ""
    @Published var loginServiceID: Int?
    @Published var loginMessage = ""

    private weak var sonos: SonosModel?
    private var context: SMAPIContext?
    private var searchCategories: [Int: [ServiceItem]] = [:]
    private var loginTask: Task<Void, Never>?
    /// Nøglerne læses fra nøgleringen én gang og huskes derefter
    private var tokens: [Int: ServiceToken] = [:]
    /// Covers til numre fra tjenesterne, nøgle "sid|id"
    private var artCache: [String: URL] = [:]
    private var artMisses: Set<String> = []
    /// Hvad SonosBar senest har startet i hvert rum (rummets navn → "sid|id")
    @Published private var startedItems: [String: String] = [:]

    init(sonos: SonosModel) {
        self.sonos = sonos
    }

    // MARK: - Opsætning

    /// Henter tjenestelisten og husstandens id fra en højttaler (én gang)
    func prepare() async {
        guard context == nil || available.isEmpty, let ip = sonos?.groups.first?.coordinatorIP else { return }
        do {
            async let hh = SonosClient.householdID(ip)
            async let serial = SonosClient.serialNumber(ip)
            async let list = SonosClient.availableServices(ip)
            context = SMAPIContext(householdID: try await hh, deviceID: try await serial)
            let all = try await list.sorted { a, b in
                let pa = Self.priority(a), pb = Self.priority(b)
                return pa != pb ? pa < pb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            // Tjenester med browser-login. Telmore og Spotify øverst.
            available = all.filter { $0.auth == "AppLink" || $0.auth == "DeviceLink" }
            let saved = Keychain.accounts()
            loggedIn = available.filter { saved.contains(String($0.id)) }

            anonymous = all.filter(\.isAnonymous)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let used = await usedServiceIDs()
            let added = Set(UserDefaults.standard.array(forKey: "services.added") as? [Int] ?? [])
            let removed = Set(UserDefaults.standard.array(forKey: "services.removed") as? [Int] ?? [])
            enabledAnonymous = anonymous.filter { (used.contains($0.id) || added.contains($0.id)) && !removed.contains($0.id) }
        } catch {
            loginMessage = String(localized: "Kunne ikke hente musiktjenesterne fra højttalerne.")
        }
    }

    /// Tjenester, husstanden bruger: dem, favoritter og afspilning kommer fra, og dem, SonosBar har set spille
    private func usedServiceIDs() async -> Set<Int> {
        var ids = Set<Int>()
        for g in sonos?.groups ?? [] {
            for uri in await SonosClient.uriSamples(g.coordinatorIP) {
                if let hit = AccountNumbers.learn(from: uri) { ids.insert(hit.sid) }
            }
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("accountNumber.") {
            if let sid = Int(key.dropFirst("accountNumber.".count)) { ids.insert(sid) }
        }
        return ids
    }

    /// Tag en tjeneste uden login med i (eller ud af) søgningen
    func setEnabled(_ svc: MusicService, _ on: Bool) {
        var added = Set(UserDefaults.standard.array(forKey: "services.added") as? [Int] ?? [])
        var removed = Set(UserDefaults.standard.array(forKey: "services.removed") as? [Int] ?? [])
        if on {
            added.insert(svc.id); removed.remove(svc.id)
            if !enabledAnonymous.contains(svc) { enabledAnonymous.append(svc) }
        } else {
            removed.insert(svc.id); added.remove(svc.id)
            enabledAnonymous.removeAll { $0.id == svc.id }
            results.removeAll { $0.service.id == svc.id }
        }
        UserDefaults.standard.set(Array(added), forKey: "services.added")
        UserDefaults.standard.set(Array(removed), forKey: "services.removed")
    }

    private static func priority(_ s: MusicService) -> Int {
        let n = s.name.lowercased()
        return n.contains("telmore") ? 0 : n.contains("spotify") ? 1 : 2
    }

    // MARK: - Login

    func login(_ svc: MusicService) {
        loginTask?.cancel()
        loginTask = Task { await runLogin(svc) }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginServiceID = nil
        loginMessage = ""
    }

    private func runLogin(_ svc: MusicService) async {
        await prepare()
        guard let ctx = context else { return }
        loginServiceID = svc.id
        defer { if loginServiceID == svc.id { loginServiceID = nil } }
        do {
            let link = try await SMAPI.getAppLink(svc, ctx)
            NSWorkspace.shared.open(link.regURL)
            loginMessage = String(localized: "Log ind på \(svc.name) i browseren …")

            // Linket gælder i ca. 10 minutter
            for _ in 0..<120 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if let token = try await SMAPI.getDeviceAuthToken(svc, ctx, link) {
                    store(token, for: svc)
                    if !loggedIn.contains(svc) { loggedIn.append(svc) }
                    loginMessage = String(localized: "Logget på \(svc.name).")
                    return
                }
            }
            loginMessage = String(localized: "Login udløb. Prøv igen.")
        } catch is CancellationError {
            return
        } catch {
            loginMessage = String(localized: "Kunne ikke logge på \(svc.name).")
        }
    }

    func logout(_ svc: MusicService) {
        Keychain.delete(String(svc.id))
        tokens[svc.id] = nil
        loggedIn.removeAll { $0.id == svc.id }
        searchCategories[svc.id] = nil
        results.removeAll { $0.service.id == svc.id }
    }

    // MARK: - Søgning

    /// Søger i alle tjenester, brugeren er logget på, og i de valgte tjenester uden login.
    /// Resultaterne vises, efterhånden som de kommer.
    func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !searchable.isEmpty else { results = []; return }
        await prepare()
        guard let ctx = context else { return }
        isSearching = true
        defer { isSearching = false }
        message = ""
        results = []
        for svc in searchable {
            let found = await search(svc, ctx, term)
            guard query.trimmingCharacters(in: .whitespaces) == term else { return } // ny søgning startet
            results.append(found)
        }
    }

    private func search(_ svc: MusicService, _ ctx: SMAPIContext, _ term: String) async -> ServiceResults {
        do {
            let categories = try await categoriesFor(svc, ctx)
            var sections: [SearchSection] = []
            for kind in SearchKind.allCases {
                guard let cat = categories.first(where: { SearchKind.of($0) == kind }) else { continue }
                let items = try await withToken(svc) { token in
                    try await SMAPI.search(svc, ctx, category: cat.id, term: term, count: 5, token: token)
                }
                if !items.isEmpty {
                    sections.append(SearchSection(id: "\(svc.id)-\(cat.id)", title: kind.title, items: items))
                }
            }
            return ServiceResults(service: svc, sections: sections,
                                  message: sections.isEmpty ? String(localized: "Ingen resultater for \"\(term)\".") : "")
        } catch {
            return ServiceResults(service: svc, sections: [], message: describe(error, svc))
        }
    }

    func clearSearch() {
        query = ""
        results = []
        message = ""
    }

    private func categoriesFor(_ svc: MusicService, _ ctx: SMAPIContext) async throws -> [ServiceItem] {
        if let c = searchCategories[svc.id] { return c }
        let c = try await withToken(svc) { token in
            try await SMAPI.getMetadata(svc, ctx, id: "search", count: 20, token: token)
        }
        searchCategories[svc.id] = c
        return c
    }

    /// Søgekategorierne hedder forskelligt hos hver tjeneste ("TrackSearch", "track", "search:channel", …)
    private enum SearchKind: CaseIterable {
        case stations, tracks, albums, playlists, artists, shows, episodes

        var title: String {
            switch self {
            case .stations: return String(localized: "Kanaler")
            case .tracks: return String(localized: "Numre")
            case .albums: return String(localized: "Albums")
            case .playlists: return String(localized: "Playlister")
            case .artists: return String(localized: "Kunstnere")
            case .shows: return String(localized: "Podcasts og programmer")
            case .episodes: return String(localized: "Udsendelser")
            }
        }

        static func of(_ c: ServiceItem) -> SearchKind? {
            let s = (c.id + " " + c.title).lowercased()
            if s.contains("episode") || s.contains("udsendelse") { return .episodes }
            if s.contains("station") || s.contains("channel") || s.contains("kanal") { return .stations }
            if s.contains("podcast") || s.contains("series") || s.contains("show") { return .shows }
            if s.contains("track") || s.contains("song") || s.contains("nummer") { return .tracks }
            if s.contains("album") { return .albums }
            if s.contains("playlist") { return .playlists }
            if s.contains("artist") { return .artists }
            return nil
        }
    }

    /// Kører et kald med tjenestens nøgle og gemmer en fornyet nøgle, hvis tjenesten sender en.
    /// Tjenester uden login kaldes uden nøgle.
    private func withToken<T>(_ svc: MusicService,
                              _ body: (ServiceToken?) async throws -> (T, ServiceToken?)) async throws -> T {
        if svc.isAnonymous { return try await body(nil).0 }
        guard let token = tokens[svc.id] ?? Keychain.load(String(svc.id)) else { throw SMAPIError.authExpired }
        tokens[svc.id] = token
        let (result, refreshed) = try await body(token)
        if let refreshed { store(refreshed, for: svc) }
        return result
    }

    private func store(_ token: ServiceToken, for svc: MusicService) {
        tokens[svc.id] = token
        Keychain.save(token, String(svc.id))
    }

    private func describe(_ error: Error, _ svc: MusicService) -> String {
        switch error {
        case SMAPIError.authExpired:
            return String(localized: "Login til \(svc.name) er udløbet. Log på igen under Indstillinger.")
        case SMAPIError.fault(let text) where text.localizedCaseInsensitiveContains("free tier"):
            return String(localized: "\(svc.name) kræver et betalt abonnement (fx Premium) for at søge via Sonos.")
        case SMAPIError.fault(let text):
            return String(localized: "\(svc.name) svarede: \(text)")
        default:
            return String(localized: "Kunne ikke kontakte \(svc.name).")
        }
    }

    // MARK: - Afspilning

    func play(_ item: ServiceItem, from svc: MusicService, in g: SonosGroup) async {
        guard let ctx = context, let sonos else { return }
        message = ""
        let sn = await accountNumber(for: svc)
        // Radiokanaler afspilles direkte
        if item.kind == .station {
            do {
                try await SonosClient.play(uri: svc.streamURI(item, accountNumber: sn),
                                           metadata: svc.streamMetadata(item), coordinatorIP: g.coordinatorIP)
                startedItems[g.name] = Self.key(svc.id, item.id)
                message = String(localized: "Spiller \"\(item.title)\" i \(g.name).")
            } catch SonosError.upnp(let code) {
                message = String(localized: "Sonos kunne ikke afspille \"\(item.title)\" (fejl \(code)).")
            } catch {
                message = describe(error, svc)
            }
            await sonos.updateStates()
            return
        }
        do {
            let tracks = try await resolveTracks(item, svc, ctx)
            for t in tracks { if let art = t.artURL { artCache[Self.key(svc.id, t.id)] = art } }
            guard let first = tracks.first else {
                message = String(localized: "Der er ikke noget at afspille i \"\(item.title)\".")
                return
            }
            let ip = g.coordinatorIP
            try await SonosClient.clearQueue(ip)
            try await SonosClient.enqueue(ip, uri: svc.trackURI(first, accountNumber: sn), metadata: svc.trackMetadata(first))
            // Start med det samme – resten lægges i køen, mens det første nummer spiller
            try await SonosClient.playQueue(ip, coordinatorUUID: g.coordinatorUUID)
            startedItems[g.name] = Self.key(svc.id, item.id)
            message = String(localized: "Spiller \"\(item.title)\" i \(g.name).")
            for t in tracks.dropFirst() {
                try await SonosClient.enqueue(ip, uri: svc.trackURI(t, accountNumber: sn), metadata: svc.trackMetadata(t))
            }
        } catch SonosError.upnp(let code) {
            message = String(localized: "Sonos kunne ikke afspille \"\(item.title)\" (fejl \(code)).")
        } catch {
            message = describe(error, svc)
        }
        await sonos.updateStates()
    }

    /// Albums, playlister og kunstnere slås op hos tjenesten, og numrene lægges i køen ét for ét
    private func resolveTracks(_ item: ServiceItem, _ svc: MusicService, _ ctx: SMAPIContext,
                               depth: Int = 0) async throws -> [ServiceItem] {
        if item.kind == .track { return [item] }
        let children = try await withToken(svc) { token in
            try await SMAPI.getMetadata(svc, ctx, id: item.id, count: 100, token: token)
        }
        // Numre i et album har ofte ikke deres eget cover – brug så albummets
        let tracks = children.filter { $0.kind == .track }.map { $0.artURL == nil ? $0.with(artURL: item.artURL) : $0 }
        if !tracks.isEmpty || depth >= 1 { return tracks }
        // Fx en kunstner: foretræk "Mest populære sange" o.l., ellers prøv mapperne efter tur
        let songWords = ["sang", "song", "track", "nummer", "numre"]
        let folders = children.filter(\.isContainer).sorted { a, b in
            let sa = songWords.contains { a.title.lowercased().contains($0) }
            let sb = songWords.contains { b.title.lowercased().contains($0) }
            return sa && !sb
        }
        for folder in folders.prefix(4) {
            let found = try await resolveTracks(folder, svc, ctx, depth: depth + 1)
            if !found.isEmpty { return found }
        }
        return []
    }

    // MARK: - Play/pause i søgevinduet

    private static func key(_ sid: Int, _ id: String) -> String { "\(sid)|\(id)" }

    /// Er det dette resultat, SonosBar senest startede i rummet, og spiller rummet stadig fra tjenesten?
    private func isCurrent(_ item: ServiceItem, from svc: MusicService, in g: SonosGroup) -> Bool {
        guard startedItems[g.name] == Self.key(svc.id, item.id) else { return false }
        return g.track?.uri.contains("sid=\(svc.id)") ?? false
    }

    func isPlaying(_ item: ServiceItem, from svc: MusicService, in g: SonosGroup?) -> Bool {
        guard let g else { return false }
        return g.state == .playing && isCurrent(item, from: svc, in: g)
    }

    /// ▶︎/⏸ på et resultat: sætter på pause eller fortsætter, hvis det allerede er startet, ellers afspilles det
    func togglePlay(_ item: ServiceItem, from svc: MusicService, in g: SonosGroup) async {
        if isCurrent(item, from: svc, in: g), let sonos {
            await sonos.toggle(g)
        } else {
            await play(item, from: svc, in: g)
        }
    }

    // MARK: - Covers

    /// Højttaleren kan ikke selv hente cover fra fx Telmore. Find det hos tjenesten og husk det.
    func artwork(forTrackURI uri: String) async -> URL? {
        guard let (sid, id) = MusicService.itemID(fromTrackURI: uri) else { return nil }
        let key = Self.key(sid, id)
        if let url = artCache[key] { return url }
        guard !artMisses.contains(key), let svc = searchable.first(where: { $0.id == sid }) else { return nil }
        await prepare()
        guard let ctx = context else { return nil }
        artMisses.insert(key) // spørg kun én gang, også hvis det fejler
        guard let url = try? await withToken(svc, { token in
            try await SMAPI.artwork(svc, ctx, id: id, token: token)
        }) else { return nil }
        artCache[key] = url
        return url
    }

    /// Kontonummeret ("sn") for tjenesten i Sonos. Det læres af noget, der er spillet fra tjenesten,
    /// og ellers ledes der efter det på højttalerne. Findes det ikke, bruges 1 – højttaleren finder
    /// selv den tilknyttede konto ud fra tjenesten (afprøvet med Telmore Musik).
    private func accountNumber(for svc: MusicService) async -> Int {
        if let n = AccountNumbers.stored(for: svc.id) { return n }
        for g in sonos?.groups ?? [] {
            for uri in await SonosClient.uriSamples(g.coordinatorIP) {
                if let hit = AccountNumbers.learn(from: uri), hit.sid == svc.id { return hit.sn }
            }
        }
        return 1
    }
}
