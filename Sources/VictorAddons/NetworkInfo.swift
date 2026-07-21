import Foundation

/// Enumerates the Mac's own LAN IPv4 addresses so it can advertise them to the
/// tablet (in the `/ping` response). The tablet — which is always reachable over
/// the Railway relay — uses these to probe the Mac **directly** over the shared
/// Wi-Fi (`http://<ip>:55123`) and prefer that lower-latency local path when it
/// answers, keeping the internet relay as the last resort.
///
/// Why not just rely on `Victor-Mac.local`? mDNS/Bonjour is routinely filtered by
/// phone-hotspot / public-Wi-Fi client isolation, so the `.local` name never
/// resolves on the tablet even when both devices sit on the same subnet. A raw IP
/// carried over the always-up relay sidesteps mDNS entirely.
enum NetworkInfo {
    /// Non-loopback, non-link-local IPv4 addresses on the physical/Wi-Fi
    /// interfaces (`en*`), best candidates first. Virtual bridges (`bridge*`,
    /// internet-sharing), VPN tunnels (`utun*`) and link-local `169.254.*` are
    /// excluded — the tablet is never on those subnets, so probing them only
    /// wastes a timeout.
    static func lanIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            // Interface must be up and running, and not loopback.
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }   // Wi-Fi / Ethernet only

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST) == 0
            guard ok else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty, !ip.hasPrefix("169.254.") else { continue }   // skip link-local
            if !addresses.contains(ip) { addresses.append(ip) }
        }
        return addresses
    }
}
