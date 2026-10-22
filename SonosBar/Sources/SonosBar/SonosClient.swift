import Foundation

enum SonosError: Error {
    case http(Int)
    case upnp(Int)
    case badResponse
}

/// Lokal UPnP/SOAP-styring af Sonos (port 1400).
enum SonosClient {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        return URLSession(configuration: c)
    }()

    // MARK: AVTransport

    static func play(_ ip: String) async throws {
        _ = try await avTransport(ip, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }
    static func pause(_ ip: String) async throws {
        _ = try await avTransport(ip, "Pause", "<InstanceID>0</InstanceID>")
    }
    static func stop(_ ip: String) async throws {
        _ = try await avTransport(ip, "Stop", "<InstanceID>0</InstanceID>")
    }
    static func next(_ ip: String) async throws {
        _ = try await avTransport(ip, "Next", "<InstanceID>0</InstanceID>")
    }
    static func previous(_ ip: String) async throws {
        _ = try await avTransport(ip, "Previous", "<InstanceID>0</InstanceID>")
    }
    static func transportState(_ ip: String) async throws -> PlayState {
        let xml = try await avTransport(ip, "GetTransportInfo", "<InstanceID>0</InstanceID>")
        return PlayState(XMLText.value(of: "CurrentTransportState", in: xml) ?? "")
    }

    /// Hvad den nuværende kilde tillader, fx ["Set", "Stop", "Play"] for radio
    static func transportActions(_ ip: String) async throws -> Set<String> {
        let xml = try await avTransport(ip, "GetCurrentTransportActions", "<InstanceID>0</InstanceID>")
        let list = XMLText.value(of: "Actions", in: xml) ?? ""
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private static func avTransport(_ ip: String, _ action: String, _ body: String) async throws -> String {
        try await soap(ip, path: "/MediaRenderer/AVTransport/Control",
                       service: "AVTransport", action: action, body: body)
    }

    // MARK: Afspilles nu

    static func nowPlaying(_ ip: String) async throws -> NowPlaying? {
        let pos = try await avTransport(ip, "GetPositionInfo", "<InstanceID>0</InstanceID>")
        let uri = XMLText.value(of: "TrackURI", in: pos) ?? ""
        AccountNumbers.learn(from: uri)

        // Faste kilder uden metadata
        if uri.hasPrefix("x-sonos-htastream:") { return NowPlaying(title: "TV", artist: "", album: "", artURL: nil, symbol: "tv") }
        if uri.hasPrefix("x-rincon-stream:") { return NowPlaying(title: "Line-in", artist: "", album: "", artURL: nil) }

        let meta = XMLText.value(of: "TrackMetaData", in: pos) ?? ""
        var title = didl("title", meta)
        var artist = didl("creator", meta)
        var album = didl("album", meta)
        var art = didl("albumArtURI", meta)

        // Radio: "Kunstner - Titel" ligger i streamContent. Mange radiokilder (fx DR's app)
        // har intet i nummerets metadata – så hentes stationens navn og logo fra medie-info.
        let stream = didl("streamContent", meta)
        let isRadio = !stream.isEmpty || didl("class", meta).isEmpty
            || ["x-rincon-mp3radio:", "x-sonosapi-stream:", "x-sonosapi-hls:", "x-sonosapi-radio:", "aac:", "hls-radio:"]
                .contains { uri.hasPrefix($0) }
        if isRadio || title.isEmpty || art.isEmpty {
            let media = (try? await avTransport(ip, "GetMediaInfo", "<InstanceID>0</InstanceID>")) ?? ""
            let mediaMeta = XMLText.value(of: "CurrentURIMetaData", in: media) ?? ""
            let station = didl("title", mediaMeta)
            if art.isEmpty { art = didl("albumArtURI", mediaMeta) }

            if isRadio {
                if !stream.isEmpty && !stream.hasPrefix("ZPSTR_") {
                    let parts = stream.components(separatedBy: " - ")
                    if parts.count >= 2 {
                        artist = cleanArtists(parts[0])
                        title = parts.dropFirst().joined(separator: " - ")
                        // Mellem numrene sender fx DR "programbeskrivelse - programnavn"
                        if artist.count > 60 { artist = "" }
                    } else {
                        title = stream; artist = ""
                    }
                    album = station
                } else if !station.isEmpty {
                    title = station; artist = ""; album = ""
                }
            } else if title.isEmpty {
                title = station
            }
        }

        if title.isEmpty && artist.isEmpty { return nil }
        if art.hasPrefix("/") { art = "http://\(ip):1400\(art)" }
        return NowPlaying(title: title, artist: artist, album: album, artURL: URL(string: art), uri: uri)
    }

    /// "/ Christopher" eller "A / B" → "Christopher" / "A, B"
    private static func cleanArtists(_ s: String) -> String {
        s.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func didl(_ tag: String, _ xml: String) -> String {
        guard !xml.isEmpty else { return "" }
        return XMLText.value(of: tag, in: xml)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Gruppe-volumen (sendes til koordinatoren og gælder hele gruppen)

    static func groupVolume(_ ip: String) async throws -> Int {
        let xml = try await groupRendering(ip, "GetGroupVolume", "<InstanceID>0</InstanceID>")
        guard let v = Int(XMLText.value(of: "CurrentVolume", in: xml) ?? "") else { throw SonosError.badResponse }
        return v
    }
    static func setGroupVolume(_ ip: String, _ volume: Int, snapshot: Bool) async throws {
        // Snapshot gemmer forholdet mellem højttalerne, så det bevares når hele gruppen skrues
        if snapshot { _ = try await groupRendering(ip, "SnapshotGroupVolume", "<InstanceID>0</InstanceID>") }
        let v = max(0, min(100, volume))
        _ = try await groupRendering(ip, "SetGroupVolume", "<InstanceID>0</InstanceID><DesiredVolume>\(v)</DesiredVolume>")
    }
    /// Lydstyrken på én højttaler (uanset gruppe)
    static func speakerVolume(_ ip: String) async throws -> Int {
        let xml = try await soap(ip, path: "/MediaRenderer/RenderingControl/Control", service: "RenderingControl",
                                 action: "GetVolume", body: "<InstanceID>0</InstanceID><Channel>Master</Channel>")
        guard let v = Int(XMLText.value(of: "CurrentVolume", in: xml) ?? "") else { throw SonosError.badResponse }
        return v
    }
    static func setSpeakerVolume(_ ip: String, _ volume: Int) async throws {
        _ = try await soap(ip, path: "/MediaRenderer/RenderingControl/Control", service: "RenderingControl",
                           action: "SetVolume",
                           body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(max(0, min(100, volume)))</DesiredVolume>")
    }

    static func groupMute(_ ip: String) async throws -> Bool {
        let xml = try await groupRendering(ip, "GetGroupMute", "<InstanceID>0</InstanceID>")
        return XMLText.value(of: "CurrentMute", in: xml) == "1"
    }
    static func setGroupMute(_ ip: String, _ muted: Bool) async throws {
        _ = try await groupRendering(ip, "SetGroupMute", "<InstanceID>0</InstanceID><DesiredMute>\(muted ? 1 : 0)</DesiredMute>")
    }

    private static func groupRendering(_ ip: String, _ action: String, _ body: String) async throws -> String {
        try await soap(ip, path: "/MediaRenderer/GroupRenderingControl/Control",
                       service: "GroupRenderingControl", action: action, body: body)
    }

    // MARK: Favoritter, playlister og indgange

    static func favorites(_ ip: String) async throws -> [LibraryItem] { try await browse(ip, "FV:2") }
    static func playlists(_ ip: String) async throws -> [LibraryItem] { try await browse(ip, "SQ:") }

    private static func browse(_ ip: String, _ objectID: String) async throws -> [LibraryItem] {
        let xml = try await soap(ip, path: "/MediaServer/ContentDirectory/Control",
                                 service: "ContentDirectory", action: "Browse", body: """
            <ObjectID>\(objectID)</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>\
            <Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>200</RequestedCount>\
            <SortCriteria></SortCriteria>
            """)
        guard let didl = XMLText.value(of: "Result", in: xml) else { throw SonosError.badResponse }
        return DIDLParser.parse(didl, ip: ip)
    }

    /// Hvilke indgange en højttaler har (TV på fx Arc/Beam, line-in på fx Five/Port)
    static func inputs(_ ip: String) async throws -> (tv: Bool, lineIn: Bool) {
        guard let url = URL(string: "http://\(ip):1400/xml/device_description.xml") else { throw SonosError.badResponse }
        let (data, _) = try await session.data(from: url)
        let text = String(decoding: data, as: UTF8.self)
        return (text.contains("service:HTControl:1"), text.contains("service:AudioIn:1"))
    }

    /// Afspiller en favorit eller playliste. Radio startes direkte; playlister, albums o.l. lægges i køen.
    static func play(_ item: LibraryItem, coordinatorIP ip: String, coordinatorUUID uuid: String) async throws {
        if item.isContainer {
            _ = try await avTransport(ip, "RemoveAllTracksFromQueue", "<InstanceID>0</InstanceID>")
            _ = try await avTransport(ip, "AddURIToQueue", """
                <InstanceID>0</InstanceID><EnqueuedURI>\(xmlEscape(item.uri))</EnqueuedURI>\
                <EnqueuedURIMetaData>\(xmlEscape(item.metadata))</EnqueuedURIMetaData>\
                <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>
                """)
            try await setURI(ip, "x-rincon-queue:\(uuid)#0", "")
        } else {
            try await setURI(ip, item.uri, item.metadata)
        }
        try await play(ip)
    }

    /// Skifter til en indgang (TV eller line-in) og starter afspilning
    static func play(uri: String, metadata: String = "", coordinatorIP ip: String) async throws {
        try await setURI(ip, uri, metadata)
        try await play(ip)
    }

    private static func setURI(_ ip: String, _ uri: String, _ metadata: String) async throws {
        _ = try await avTransport(ip, "SetAVTransportURI", """
            <InstanceID>0</InstanceID><CurrentURI>\(xmlEscape(uri))</CurrentURI>\
            <CurrentURIMetaData>\(xmlEscape(metadata))</CurrentURIMetaData>
            """)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Musiktjenester

    static func householdID(_ ip: String) async throws -> String {
        let xml = try await soap(ip, path: "/DeviceProperties/Control", service: "DeviceProperties",
                                 action: "GetHouseholdID", body: "")
        guard let id = XMLText.value(of: "CurrentHouseholdID", in: xml) else { throw SonosError.badResponse }
        return id
    }

    /// Højttalerens serienummer, som tjenesterne bruger som enheds-id
    static func serialNumber(_ ip: String) async throws -> String {
        guard let url = URL(string: "http://\(ip):1400/xml/device_description.xml") else { throw SonosError.badResponse }
        let (data, _) = try await session.data(from: url)
        guard let s = XMLText.value(of: "serialNum", in: String(decoding: data, as: UTF8.self)) else {
            throw SonosError.badResponse
        }
        return s
    }

    static func availableServices(_ ip: String) async throws -> [MusicService] {
        let xml = try await soap(ip, path: "/MusicServices/Control", service: "MusicServices",
                                 action: "ListAvailableServices", body: "")
        guard let list = XMLText.value(of: "AvailableServiceDescriptorList", in: xml) else { throw SonosError.badResponse }
        return ServiceListParser.parse(list)
    }

    static func clearQueue(_ ip: String) async throws {
        _ = try await avTransport(ip, "RemoveAllTracksFromQueue", "<InstanceID>0</InstanceID>")
    }

    static func enqueue(_ ip: String, uri: String, metadata: String) async throws {
        _ = try await avTransport(ip, "AddURIToQueue", """
            <InstanceID>0</InstanceID><EnqueuedURI>\(xmlEscape(uri))</EnqueuedURI>\
            <EnqueuedURIMetaData>\(xmlEscape(metadata))</EnqueuedURIMetaData>\
            <DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>
            """)
    }

    static func playQueue(_ ip: String, coordinatorUUID uuid: String) async throws {
        try await setURI(ip, "x-rincon-queue:\(uuid)#0", "")
        try await play(ip)
    }

    /// Adresser fra det, højttaleren spiller, har i køen og har som favoritter. Bruges til at finde
    /// kontonummeret ("sn") for en tjeneste, som Sonos-appen har tilknyttet.
    static func uriSamples(_ ip: String) async -> [String] {
        var out: [String] = []
        if let pos = try? await avTransport(ip, "GetPositionInfo", "<InstanceID>0</InstanceID>"),
           let uri = XMLText.value(of: "TrackURI", in: pos) { out.append(uri) }
        if let media = try? await avTransport(ip, "GetMediaInfo", "<InstanceID>0</InstanceID>"),
           let uri = XMLText.value(of: "CurrentURI", in: media) { out.append(uri) }
        for objectID in ["Q:0", "FV:2"] {
            if let items = try? await browse(ip, objectID) { out += items.map(\.uri) }
        }
        return out
    }

    // MARK: Gruppering

    /// Lader en højttaler spille med i gruppen, som koordinatoren styrer
    static func join(_ memberIP: String, coordinatorUUID: String) async throws {
        try await setURI(memberIP, "x-rincon:\(coordinatorUUID)", "")
    }

    /// Tager en højttaler ud af sin gruppe, så den bliver et rum for sig selv
    static func leaveGroup(_ memberIP: String) async throws {
        _ = try await avTransport(memberIP, "BecomeCoordinatorOfStandaloneGroup", "<InstanceID>0</InstanceID>")
    }

    // MARK: Topologi (rum og grupper)

    static func groups(via ip: String) async throws -> [SonosGroup] {
        let xml = try await soap(ip, path: "/ZoneGroupTopology/Control",
                                 service: "ZoneGroupTopology", action: "GetZoneGroupState", body: "")
        guard let inner = XMLText.value(of: "ZoneGroupState", in: xml) else { throw SonosError.badResponse }
        return TopologyParser.parse(inner)
    }

    // MARK: SOAP

    private static func soap(_ ip: String, path: String, service: String,
                             action: String, body: String) async throws -> String {
        guard let url = URL(string: "http://\(ip):1400\(path)") else { throw SonosError.badResponse }
        let urn = "urn:schemas-upnp-org:service:\(service):1"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(urn)">\(body)</u:\(action)></s:Body></s:Envelope>
        """.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if let e = XMLText.value(of: "errorCode", in: text), let n = Int(e) { throw SonosError.upnp(n) }
            throw SonosError.http(code)
        }
        return text
    }
}

// MARK: - XML-hjælpere

/// Henter tekstindholdet af første element med et givet navn (namespace-præfiks ignoreres).
final class XMLText: NSObject, XMLParserDelegate {
    private let target: String
    private var inside = false
    private var done = false
    private var buffer = ""

    private init(target: String) { self.target = target }

    static func value(of tag: String, in xml: String) -> String? {
        let p = XMLText(target: tag)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()
        return p.done ? p.buffer : nil
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if !done && local(elementName) == target { inside = true; buffer = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inside { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if inside && local(elementName) == target {
            inside = false; done = true
            parser.abortParsing()
        }
    }
}

final class TopologyParser: NSObject, XMLParserDelegate {
    private struct Member { let uuid: String; let ip: String; let name: String; let visible: Bool; let isCoordinator: Bool }
    private struct Group { let id: String; let coordinator: String; var members: [Member] = [] }
    private var groups: [Group] = []
    private var depthInMember = 0

    static func parse(_ xml: String) -> [SonosGroup] {
        let p = TopologyParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()

        return p.groups.compactMap { g -> SonosGroup? in
            let visible = g.members.filter(\.visible)
            guard let coord = g.members.first(where: \.isCoordinator), !visible.isEmpty else { return nil }
            var names: [String] = []
            for m in visible where !names.contains(m.name) { names.append(m.name) }
            let first = coord.visible ? coord.name : names[0]
            let others = names.filter { $0 != first }
            let name = others.isEmpty ? first : "\(first) + \(others.count)"
            return SonosGroup(id: g.id, name: name, coordinatorIP: coord.ip, state: .unknown,
                              coordinatorUUID: coord.uuid,
                              members: visible.map { GroupMember(uuid: $0.uuid, ip: $0.ip, name: $0.name) })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch elementName {
        case "ZoneGroup":
            groups.append(Group(id: a["ID"] ?? UUID().uuidString, coordinator: a["Coordinator"] ?? ""))
        case "ZoneGroupMember":
            // Satellitter (surround/sub) ligger som <Satellite> og springes over automatisk
            guard !groups.isEmpty, let host = URL(string: a["Location"] ?? "")?.host else { return }
            let uuid = a["UUID"] ?? ""
            let invisible = a["Invisible"] == "1" || a["IsZoneBridge"] == "1"
            let i = groups.count - 1
            groups[i].members.append(Member(uuid: uuid, ip: host, name: a["ZoneName"] ?? "Sonos",
                                            visible: !invisible,
                                            isCoordinator: uuid == groups[i].coordinator))
        default:
            break
        }
    }
}

/// Læser <item>/<container> fra et DIDL-Lite-svar (favoritter og playlister)
final class DIDLParser: NSObject, XMLParserDelegate {
    private struct Entry { var id = ""; var isContainerElement = false
        var fields: [String: String] = [:] }
    private var entries: [Entry] = []
    private var current: Entry?
    private var field: String?
    private var buffer = ""

    static func parse(_ xml: String, ip: String) -> [LibraryItem] {
        let p = DIDLParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()

        return p.entries.compactMap { e -> LibraryItem? in
            let title = e.fields["title"] ?? ""
            let uri = e.fields["res"] ?? ""
            guard !title.isEmpty, !uri.isEmpty else { return nil }
            // Favoritter har den egentlige metadata i resMD; playlister beskriver sig selv
            let meta = e.fields["resMD"] ?? ""
            let cls = (meta.isEmpty ? nil : XMLText.value(of: "class", in: meta)) ?? e.fields["class"] ?? ""
            var art = e.fields["albumArtURI"] ?? ""
            if art.hasPrefix("/") { art = "http://\(ip):1400\(art)" }
            return LibraryItem(id: e.id, title: title, uri: uri, metadata: meta,
                               artURL: URL(string: art),
                               isContainer: e.isContainerElement || cls.contains("container"))
        }
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        let name = local(elementName)
        if name == "item" || name == "container" {
            current = Entry(id: a["id"] ?? UUID().uuidString, isContainerElement: name == "container")
        } else if current != nil, field == nil {
            field = name; buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = local(elementName)
        if name == "item" || name == "container" {
            if let c = current { entries.append(c) }
            current = nil
        } else if name == field {
            if current?.fields[name] == nil {
                current?.fields[name] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            field = nil
        }
    }
}
