import Foundation
import Network

struct DiscoveredBulb: Equatable {
    let host: String
    let port: UInt16
}

/// Finds Yeelight bulbs on the local network: SSDP multicast first, then a
/// verified TCP probe of the local subnet as a fallback.
enum Discovery {
    static let bulbPort: UInt16 = 55443
    private static let ignoredInterfacePrefixes = ["utun", "bridge", "awdl", "llw", "vmnet", "vboxnet", "docker", "veth", "ipsec", "ppp", "lo"]
    private static let queue = DispatchQueue(label: "yeelight.discovery", qos: .userInitiated, attributes: .concurrent)

    /// Runs discovery off the main thread and calls `completion` on the main queue.
    static func scan(completion: @escaping ([DiscoveredBulb]) -> Void) {
        queue.async {
            var found = scanSSDP(timeout: 1.5)
            if found.isEmpty {
                found = scanSubnet()
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    // MARK: SSDP

    static func scanSSDP(timeout: TimeInterval) -> [DiscoveredBulb] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var recvTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1982).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: \"ssdp:discover\"\r\nST: wifi_bulb\r\n\r\n"
        // Send on every LAN interface: the default multicast route may be a
        // VPN tunnel that never reaches the bulb.
        let interfaces = localIPv4Interfaces().map(\.address)
        func sendOnce() {
            _ = message.withCString { ptr in
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        func send() {
            if interfaces.isEmpty { return sendOnce() }
            for address in interfaces {
                var iface = in_addr()
                guard inet_pton(AF_INET, address, &iface) == 1 else { continue }
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
                sendOnce()
            }
        }

        send()
        var resent = false
        var found: [DiscoveredBulb] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            // Multicast over Wi-Fi is lossy: ask a second time.
            if !resent && Date().timeIntervalSince(start) > 0.3 {
                send()
                resent = true
            }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { break }
            guard n > 0, let text = String(bytes: buffer[0..<n], encoding: .utf8) else { continue }
            if let bulb = parseSSDPResponse(text), !found.contains(bulb) {
                found.append(bulb)
            }
        }
        return found
    }

    static func parseSSDPResponse(_ text: String) -> DiscoveredBulb? {
        for line in text.components(separatedBy: "\r\n") {
            // Match case-insensitively on the same string we slice, so
            // case-folding can never shift indices.
            guard line.range(of: "location:", options: [.caseInsensitive, .anchored]) != nil,
                  let range = line.range(of: "yeelight://", options: .caseInsensitive) else { continue }
            let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: ":")
            guard parts.count == 2, isIPv4(String(parts[0])), let port = UInt16(parts[1]) else { return nil }
            return DiscoveredBulb(host: String(parts[0]), port: port)
        }
        return nil
    }

    // MARK: Subnet probe

    static func scanSubnet() -> [DiscoveredBulb] {
        var hosts: [String] = []
        var seen = Set<String>()
        for (address, netmask) in localIPv4Interfaces() {
            for host in hostsForInterface(address: address, netmask: netmask) where seen.insert(host).inserted {
                hosts.append(host)
            }
        }

        var found: [DiscoveredBulb] = []
        let lock = NSLock()
        let batchSize = 64
        for start in stride(from: 0, to: hosts.count, by: batchSize) {
            let group = DispatchGroup()
            for host in hosts[start..<min(start + batchSize, hosts.count)] {
                group.enter()
                probe(host: host, port: bulbPort, timeout: 0.7) { ok in
                    if ok {
                        lock.lock()
                        found.append(DiscoveredBulb(host: host, port: bulbPort))
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.wait()
        }
        return found.sorted { $0.host.compare($1.host, options: .numeric) == .orderedAscending }
    }

    /// Connects to `host:port` and confirms the peer answers a Yeelight
    /// `get_prop`, so unrelated devices with port 55443 open are skipped.
    static func probe(host: String, port: UInt16, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return completion(false) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let probeQueue = DispatchQueue(label: "yeelight.probe")
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(ok)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = Data("{\"id\":1,\"method\":\"get_prop\",\"params\":[\"power\"]}\r\n".utf8)
                connection.send(content: request, completion: .contentProcessed { error in
                    if error != nil { probeQueue.async { finish(false) } }
                })
                // The reply may arrive in several segments: read until a full line.
                var received = Data()
                func readMore() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                        probeQueue.async {
                            if let data { received.append(data) }
                            let text = (String(data: received, encoding: .utf8) ?? "").replacingOccurrences(of: " ", with: "")
                            if text.contains("\r\n") || done || error != nil || received.count > 4096 {
                                finish(text.contains("\"id\":1") && (text.contains("\"result\"") || text.contains("\"error\"")))
                            } else if !finished {
                                readMore()
                            }
                        }
                    }
                }
                readMore()
            case .failed, .cancelled, .waiting:
                probeQueue.async { finish(false) }
            default:
                break
            }
        }
        connection.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    // MARK: Helpers

    static func isIPv4(_ string: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, string, &addr) == 1
    }

    /// Hosts to probe for one interface: its real range when /24 or smaller, otherwise its /24.
    static func hostsForInterface(address: String, netmask: String) -> [String] {
        func toInt(_ ip: String) -> UInt32? {
            let octets = ip.split(separator: ".").compactMap { UInt32($0) }
            guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
            return octets.reduce(0) { ($0 << 8) | $1 }
        }
        func toIP(_ n: UInt32) -> String {
            [24, 16, 8, 0].map { String((n >> UInt32($0)) & 255) }.joined(separator: ".")
        }
        guard let addr = toInt(address) else { return [] }
        let minMask: UInt32 = 0xFFFF_FF00
        let mask = max(toInt(netmask) ?? minMask, minMask)
        let network = addr & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast).filter { $0 != addr }.map(toIP)
    }

    static func localIPv4Interfaces() -> [(address: String, netmask: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            let flags = Int32(iface.ifa_flags)
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = iface.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: iface.ifa_name)
            if ignoredInterfacePrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            result.append((ipString(addr), ipString(maskPtr)))
        }
        return result
    }

    private static func ipString(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return String(cString: host)
    }
}
