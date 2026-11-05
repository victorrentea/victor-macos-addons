import Foundation
import Network

/// Who may call what on 55123. It has to listen on every interface, because the
/// tablet reaches it on the Mac's LAN IP, and it has no authentication, so a venue
/// Wi-Fi is hostile: **anything from off this Mac gets the tablet's routes and
/// nothing else**. That leaves out `/open`, `/test/*`, `/hands-off/*`, `/link/*`.
///
/// Default-deny on purpose: a route added tomorrow stays local until someone
/// decides otherwise. USB is local too (`adb reverse` arrives on loopback).
/// `HttpAccessPolicyTests` pins this list to the tablet's own source.
enum HttpAccessPolicy {
    private static let exact: Set<String> = ["/ping", "/tiles", "/usage", "/videos",
                                             "/alarm", "/bt-compensation"]
    private static let prefixes = ["/sound/", "/sounds/", "/tiles/", "/usage/", "/video/",
                                   "/effect/", "/alarm/", "/bt-compensation/"]

    /// `path` as it came off the wire, query included. Proxied routes are matched
    /// by prefix and forwarded verbatim, so a dot segment could walk out of an
    /// allowed prefix: it is refused rather than normalised.
    static func tabletMayCall(_ path: String) -> Bool {
        guard let pathOnly = URLComponents(string: "http://x" + path)?.path else { return false }
        if pathOnly.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) { return false }
        return exact.contains(pathOnly) || prefixes.contains { pathOnly.hasPrefix($0) }
    }

    /// Fails closed: whatever is not provably loopback counts as the network. The
    /// listener is dual-stack, so an IPv4 peer can show up as a mapped IPv6 address.
    static func isLocal(_ peer: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = peer else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback || address.asIPv4?.isLoopback == true
        default:
            return false
        }
    }
}
