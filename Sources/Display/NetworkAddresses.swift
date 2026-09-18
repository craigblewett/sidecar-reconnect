//  NetworkAddresses.swift — which address should the tablet dial?
//
//  Over WiFi that's the Mac's LAN address. But a tablet sharing its connection
//  over USB ("USB tethering") puts the Mac on a second, private network that
//  exists only along the cable — and that link is worth preferring, because it
//  doesn't share the air with everything else in the building.
//
//  The USB link is found by elimination rather than by name: interface names
//  are assigned in order of appearance, so the tether can be en5 on one machine
//  and en12 on another. What distinguishes it is that it carries a routable
//  address while *not* being the interface the default route uses.

import Foundation

enum NetworkAddresses {

    struct Candidate {
        let interface: String
        let address: String
        /// A private link to something plugged in, rather than the way this Mac
        /// reaches the internet.
        let isDirectLink: Bool
    }

    /// Every IPv4 address a client on the same network could reach us at,
    /// direct links first.
    static func candidates() -> [Candidate] {
        let defaultInterface = defaultRouteInterface()
        var found: [Candidate] = []

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            // Link-local means nothing answered DHCP — not somewhere to point a
            // tablet. (The iPad's own USB interfaces sit here.)
            guard !address.hasPrefix("169.254.") else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            found.append(Candidate(interface: name, address: address,
                                   isDirectLink: name != defaultInterface))
        }
        return found.sorted { $0.isDirectLink && !$1.isDirectLink }
    }

    /// The address to hand the user: a direct cable link if there is one,
    /// otherwise wherever this Mac normally lives.
    static func preferred() -> Candidate? { candidates().first }

    private static func defaultRouteInterface() -> String? {
        let result = shell("/sbin/route", ["-n", "get", "default"], timeout: 5)
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
