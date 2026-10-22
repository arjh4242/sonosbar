import Foundation
import Darwin

/// Finder Sonos-højttalere på det lokale netværk via SSDP (UPnP-multicast).
enum SSDP {
    static func discover(timeout: TimeInterval = 2.5) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        let msg = Array((
            "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 1\r\n" +
            "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        ).utf8)

        func send() {
            _ = msg.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        send()
        send() // UDP kan tabes – send to gange

        var ips: [String] = []
        let size = 2048
        var buffer = [UInt8](repeating: 0, count: size)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let n = recv(fd, &buffer, size, 0)
            guard n > 0 else { continue }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).uppercased() == "LOCATION",
                      let host = URL(string: parts[1].trimmingCharacters(in: .whitespaces))?.host,
                      !ips.contains(host) else { continue }
                ips.append(host)
            }
        }
        return ips
    }
}
