import Foundation
import Security

// Musiktjenester (fx Telmore Musik og Spotify) via Sonos' tjeneste-API "SMAPI".
// Login sker med AppLink: brugeren logger ind i browseren, og SonosBar får sin egen nøgle
// til at søge i kataloget. Selve afspilningen sker med den konto, der er tilknyttet i Sonos-appen.

struct MusicService: Identifiable, Hashable {
    let id: Int          // Sonos' tjeneste-id ("sid"), fx 175 for Telmore Musik
    let name: String
    let endpoint: URL
    let auth: String     // "AppLink", "DeviceLink", …

    /// Bruges i Sonos' metadata, fx SA_RINCON44807_… for Telmore
    var serviceType: Int { id * 256 + 7 }
    var isSpotify: Bool { name.localizedCaseInsensitiveContains("spotify") }
    /// Tjenester som DR LYD og TuneIn kræver ikke login
    var isAnonymous: Bool { auth == "Anonymous" }

    /// Sonos' kontobeskrivelse i metadata. Tjenester uden login har ingen konto-del.
    var accountDescriptor: String {
        isAnonymous ? "SA_RINCON\(serviceType)_" : "SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token"
    }
}

struct ServiceItem: Identifiable, Equatable {
    enum Kind { case track, album, playlist, artist, station, other }

    let id: String
    let title: String
    let artist: String
    let album: String
    let artURL: URL?
    let kind: Kind
    let mimeType: String
    let isContainer: Bool

    var subtitle: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " · ") }

    func with(artURL url: URL?) -> ServiceItem {
        ServiceItem(id: id, title: title, artist: artist, album: album, artURL: url, kind: kind,
                    mimeType: mimeType, isContainer: isContainer)
    }
}

struct ServiceToken: Codable {
    var token: String
    var key: String
}

enum SMAPIError: Error {
    case notLinkedYet
    case authExpired
    case fault(String)
    case http(Int)
    case badResponse
}

// MARK: - Nøglering

/// Adgangsnøglerne gemmes i macOS' nøglering – aldrig i almindelige indstillinger
enum Keychain {
    private static let service = "dk.jayh.sonosbar.musicservice"

    /// Hvilke tjenester der er gemt nøgler for. Læser kun navnene, ikke selve nøglerne,
    /// så macOS ikke beder om adgang til nøgleringen bare for at vise login-status.
    static func accounts() -> Set<String> {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    static func load(_ account: String) -> ServiceToken? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServiceToken.self, from: data)
    }

    static func save(_ token: ServiceToken, _ account: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SonosBar – musiktjeneste"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - SMAPI

/// Hvem der spørger: Sonos-husstanden og en af dens højttalere
struct SMAPIContext {
    let householdID: String
    let deviceID: String
}

enum SMAPI {
    private static let ns = "http://www.sonos.com/Services/1.1"
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        return URLSession(configuration: c)
    }()

    struct AppLink {
        let regURL: URL
        let linkCode: String
        let linkDeviceID: String
    }

    static func getAppLink(_ svc: MusicService, _ ctx: SMAPIContext) async throws -> AppLink {
        let (xml, _) = try await call(svc, ctx, "getAppLink", "<householdId>\(esc(ctx.householdID))</householdId>", token: nil)
        guard let reg = XMLText.value(of: "regUrl", in: xml), let url = URL(string: reg),
              let code = XMLText.value(of: "linkCode", in: xml) else { throw SMAPIError.badResponse }
        return AppLink(regURL: url, linkCode: code, linkDeviceID: XMLText.value(of: "linkDeviceId", in: xml) ?? "")
    }

    /// Spørg om brugeren er færdig med at logge ind. `nil` = ikke endnu.
    static func getDeviceAuthToken(_ svc: MusicService, _ ctx: SMAPIContext, _ link: AppLink) async throws -> ServiceToken? {
        var body = "<householdId>\(esc(ctx.householdID))</householdId><linkCode>\(esc(link.linkCode))</linkCode>"
        if !link.linkDeviceID.isEmpty { body += "<linkDeviceId>\(esc(link.linkDeviceID))</linkDeviceId>" }
        do {
            let (xml, _) = try await call(svc, ctx, "getDeviceAuthToken", body, token: nil)
            guard let t = XMLText.value(of: "authToken", in: xml) else { throw SMAPIError.badResponse }
            return ServiceToken(token: t, key: XMLText.value(of: "privateKey", in: xml) ?? "")
        } catch SMAPIError.notLinkedYet {
            return nil
        }
    }

    static func getMetadata(_ svc: MusicService, _ ctx: SMAPIContext, id: String, count: Int,
                            token: ServiceToken?) async throws -> ([ServiceItem], ServiceToken?) {
        let body = "<id>\(esc(id))</id><index>0</index><count>\(count)</count>"
        let (xml, refreshed) = try await call(svc, ctx, "getMetadata", body, token: token)
        return (SMAPIItemParser.parse(xml), refreshed)
    }

    /// Cover til et enkelt nummer. Svaret er ét element uden <mediaMetadata> omkring.
    static func artwork(_ svc: MusicService, _ ctx: SMAPIContext, id: String,
                        token: ServiceToken?) async throws -> (URL?, ServiceToken?) {
        let (xml, refreshed) = try await call(svc, ctx, "getMediaMetadata", "<id>\(esc(id))</id>", token: token)
        return (XMLText.value(of: "albumArtURI", in: xml).flatMap { URL(string: $0) }, refreshed)
    }

    static func search(_ svc: MusicService, _ ctx: SMAPIContext, category: String, term: String, count: Int,
                       token: ServiceToken?) async throws -> ([ServiceItem], ServiceToken?) {
        let body = "<id>\(esc(category))</id><term>\(esc(term))</term><index>0</index><count>\(count)</count>"
        let (xml, refreshed) = try await call(svc, ctx, "search", body, token: token)
        return (SMAPIItemParser.parse(xml), refreshed)
    }

    /// Kalder tjenesten. Beder den om at forny nøglen, gøres det automatisk, og den nye nøgle returneres.
    private static func call(_ svc: MusicService, _ ctx: SMAPIContext, _ action: String, _ body: String,
                             token: ServiceToken?, retried: Bool = false) async throws -> (String, ServiceToken?) {
        var login = ""
        if let token {
            login = "<loginToken><token>\(esc(token.token))</token><key>\(esc(token.key))</key>"
                + "<householdId>\(esc(ctx.householdID))</householdId></loginToken>"
        }
        var req = URLRequest(url: svc.endpoint)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(ns)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        // Nogle tjenester svarer kun klienter, der præsenterer sig som en Sonos-højttaler
        req.setValue("Linux UPnP/1.0 Sonos/80.1-55014 (ZPS9)", forHTTPHeaderField: "User-Agent")
        req.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Header>\
        <credentials xmlns="\(ns)"><deviceId>\(esc(ctx.deviceID))</deviceId>\
        <deviceProvider>Sonos</deviceProvider>\(login)</credentials></s:Header>\
        <s:Body><\(action) xmlns="\(ns)">\(body)</\(action)></s:Body></s:Envelope>
        """.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return (text, nil) }

        let faultCode = XMLText.value(of: "faultcode", in: text) ?? ""
        let faultString = XMLText.value(of: "faultstring", in: text) ?? ""
        let fault = faultCode + " " + faultString

        if fault.localizedCaseInsensitiveContains("NOT_LINKED") { throw SMAPIError.notLinkedYet }
        if fault.localizedCaseInsensitiveContains("TokenRefreshRequired"), !retried,
           let t = XMLText.value(of: "authToken", in: text) {
            let fresh = ServiceToken(token: t, key: XMLText.value(of: "privateKey", in: text) ?? token?.key ?? "")
            let (xml, _) = try await call(svc, ctx, action, body, token: fresh, retried: true)
            return (xml, fresh)
        }
        if fault.localizedCaseInsensitiveContains("AuthTokenExpired")
            || fault.localizedCaseInsensitiveContains("LoginUnauthorized") { throw SMAPIError.authExpired }
        if !faultString.isEmpty { throw SMAPIError.fault(faultString) }
        throw SMAPIError.http(code)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Kontonumre

/// Sonos nummererer de tilknyttede tjenestekonti ("sn" i afspilningsadresserne). Nummeret
/// læres, når SonosBar ser noget fra tjenesten spille, og huskes.
enum AccountNumbers {
    private static let regex = try? NSRegularExpression(pattern: "[?&]sid=(\\d+)&(?:[^&\"<]*&)*?sn=(\\d+)")

    static func stored(for sid: Int) -> Int? {
        UserDefaults.standard.object(forKey: "accountNumber.\(sid)") as? Int
    }

    /// Finder sid og sn i en adresse og gemmer dem. Returnerer (sid, sn), hvis der var nogen.
    @discardableResult
    static func learn(from uri: String) -> (sid: Int, sn: Int)? {
        guard let rx = regex,
              let m = rx.firstMatch(in: uri, range: NSRange(uri.startIndex..., in: uri)),
              let r1 = Range(m.range(at: 1), in: uri), let r2 = Range(m.range(at: 2), in: uri),
              let sid = Int(uri[r1]), let sn = Int(uri[r2]) else { return nil }
        if stored(for: sid) != sn { UserDefaults.standard.set(sn, forKey: "accountNumber.\(sid)") }
        return (sid, sn)
    }
}

// MARK: - Afspilning via Sonos

extension MusicService {
    /// Sonos koder tjeneste-id'er med alt undtagen bogstaver, tal og -._ procent-kodet, med små hex-tegn
    static func sonosEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F: out.append(Character(UnicodeScalar(b)))
            default: out += String(format: "%%%02x", b)
            }
        }
        return out
    }

    /// Tjenestens eget id for nummeret i en afspilningsadresse, fx
    /// "x-sonos-http:catalog%3atrack%40…%2f3011073.mp4?sid=175&…" → (175, "catalog:track@~catalog/1387/tracks/3011073")
    static func itemID(fromTrackURI uri: String) -> (sid: Int, id: String)? {
        guard let colon = uri.firstIndex(of: ":"), let q = uri.firstIndex(of: "?"), colon < q,
              let sidRange = uri.range(of: "sid=") else { return nil }
        var enc = String(uri[uri.index(after: colon)..<q])
        for ext in [".mp4", ".mp3", ".flac"] where enc.hasSuffix(ext) { enc.removeLast(ext.count) }
        let sidDigits = uri[sidRange.upperBound...].prefix { $0.isNumber }
        guard let sid = Int(sidDigits), let id = enc.removingPercentEncoding, !id.isEmpty else { return nil }
        return (sid, id)
    }

    /// Adresse, som højttaleren kan afspille et nummer fra. `sn` er kontoens nummer i Sonos.
    func trackURI(_ item: ServiceItem, accountNumber sn: Int) -> String {
        let enc = Self.sonosEncode(item.id)
        if isSpotify {
            return "x-sonos-spotify:\(enc)?sid=\(id)&flags=8224&sn=\(sn)"
        }
        let ext: String
        switch item.mimeType.lowercased() {
        case "audio/mpeg", "audio/mp3": ext = "mp3"
        case "audio/flac", "audio/x-flac": ext = "flac"
        default: ext = "mp4"
        }
        return "x-sonos-http:\(enc).\(ext)?sid=\(id)&flags=8232&sn=\(sn)"
    }

    /// Adresse til en radiokanal/-strøm, som afspilles direkte (ikke via køen)
    func streamURI(_ item: ServiceItem, accountNumber sn: Int) -> String {
        let enc = Self.sonosEncode(item.id)
        if item.mimeType.lowercased().contains("mpegurl") {
            return "x-sonosapi-hls:\(enc)?sid=\(id)&flags=8232&sn=\(sn)"
        }
        return "x-sonosapi-stream:\(enc)?sid=\(id)&flags=8224&sn=\(sn)"
    }

    func streamMetadata(_ item: ServiceItem) -> String {
        let e = SMAPI.esc
        var art = ""
        if let url = item.artURL { art = "<upnp:albumArtURI>\(e(url.absoluteString))</upnp:albumArtURI>" }
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="10092020\(e(Self.sonosEncode(item.id)))" parentID="-1" restricted="true">\
        <dc:title>\(e(item.title))</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\(art)\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\(accountDescriptor)</desc>\
        </item></DIDL-Lite>
        """
    }

    /// Metadata der får "afspilles nu" og køen til at vise titel, kunstner og cover
    func trackMetadata(_ item: ServiceItem) -> String {
        let prefix = isSpotify ? "00032020" : "10032020"
        let e = SMAPI.esc
        var art = ""
        if let url = item.artURL { art = "<upnp:albumArtURI>\(e(url.absoluteString))</upnp:albumArtURI>" }
        return """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="\(prefix)\(e(Self.sonosEncode(item.id)))" parentID="-1" restricted="true">\
        <dc:title>\(e(item.title))</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class>\
        <dc:creator>\(e(item.artist))</dc:creator><upnp:album>\(e(item.album))</upnp:album>\(art)\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">\
        \(accountDescriptor)</desc></item></DIDL-Lite>
        """
    }
}

// MARK: - Parsere

/// Læser <mediaCollection>/<mediaMetadata> fra et SMAPI-svar
final class SMAPIItemParser: NSObject, XMLParserDelegate {
    private struct Entry { var isCollection: Bool; var depth: Int; var fields: [String: String] = [:] }
    private var entries: [Entry] = []
    private var current: Entry?
    private var depth = 0
    private var buffer = ""

    static func parse(_ xml: String) -> [ServiceItem] {
        let p = SMAPIItemParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()

        return p.entries.compactMap { e -> ServiceItem? in
            let f = e.fields
            guard let id = f["id"], let title = f["title"], !id.isEmpty else { return nil }
            let type = (f["itemType"] ?? "").lowercased()
            let kind: ServiceItem.Kind
            switch type {
            case "stream": kind = .station
            case "track", "program": kind = e.isCollection ? .other : .track
            case "album": kind = .album
            case "playlist", "albumlist", "favorites": kind = .playlist
            case "artist": kind = .artist
            default: kind = e.isCollection ? .other : .track
            }
            return ServiceItem(id: id, title: title, artist: f["artist"] ?? "", album: f["album"] ?? "",
                               artURL: URL(string: f["albumArtURI"] ?? ""), kind: kind,
                               mimeType: f["mimeType"] ?? "", isContainer: e.isCollection)
        }
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        depth += 1
        let name = local(elementName)
        if name == "mediaCollection" || name == "mediaMetadata" {
            current = Entry(isCollection: name == "mediaCollection", depth: depth)
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = local(elementName)
        if let c = current {
            if depth == c.depth {
                entries.append(c)
                current = nil
            } else if current?.fields[name] == nil {
                let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { current?.fields[name] = text }
            }
        }
        buffer = ""
        depth -= 1
    }
}

/// Læser tjenestelisten fra en højttaler (MusicServices/ListAvailableServices)
final class ServiceListParser: NSObject, XMLParserDelegate {
    private var services: [MusicService] = []
    private var pending: (id: Int, name: String, url: URL)?

    static func parse(_ xml: String) -> [MusicService] {
        let p = ServiceListParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()
        return p.services
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch elementName {
        case "Service":
            if let id = Int(a["Id"] ?? ""), let name = a["Name"],
               let url = URL(string: a["SecureUri"] ?? a["Uri"] ?? "") {
                pending = (id, name, url)
            }
        case "Policy":
            if let p = pending {
                services.append(MusicService(id: p.id, name: p.name, endpoint: p.url, auth: a["Auth"] ?? ""))
                pending = nil
            }
        default:
            break
        }
    }
}
