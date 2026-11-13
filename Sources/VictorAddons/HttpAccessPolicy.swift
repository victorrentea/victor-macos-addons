import CryptoKit
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
///
/// **Those routes also need the tablet's `X-Lan-Token`, once it has shown one.** A
/// tablet on an older build sends none, and it treats a refusal as an answer rather
/// than falling back to the relay, so enforcing from day one would cut it off. So
/// the first valid token arms the check for good (`armedKey`), which also proves
/// the new build works before anything is ever refused.
enum HttpAccessPolicy {
    enum Decision: Equatable {
        case serve
        case routeRefused   // 403: not a tablet route
        case tokenRefused   // 401: a tablet route, without the tablet's token
    }

    static let armedKey = "http.lan.token.armed"

    static func decide(path: String, local: Bool, tokenValid: Bool, armed: Bool) -> Decision {
        if local { return .serve }
        if !tabletMayCall(path) { return .routeRefused }
        return armed && !tokenValid ? .tokenRefused : .serve
    }

    /// Derived, not the relay's token itself: this crosses a shared Wi-Fi in clear
    /// HTTP, and a sniffed copy must not open the relay, the door from the internet.
    /// `lanTokenFrom` on the tablet computes the same value.
    static func lanToken(fromBridgeToken token: String) -> String? {
        guard !token.isEmpty else { return nil }
        return SHA256.hash(data: Data("victor-lan-v1:\(token)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// One header of the request head, by lower-case name.
    static func header(_ name: String, inRequest raw: String) -> String? {
        let head = raw.components(separatedBy: "\r\n\r\n").first ?? raw
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 🌐 **Loopback is not "me"**: a web page open in a browser on this Mac also
    /// arrives on 127.0.0.1, and every route here is a GET it can fire blind
    /// (`<img src=…>`, a navigated popup). So a local request is refused when it
    /// carries a browser's fingerprints: an `Origin` that is not ours or an
    /// extension's, a `Sec-Fetch-Site` saying another site started it, a `Host`
    /// that is not this loopback port (DNS rebinding), or a head that did not
    /// fit the first read (headers pushed out of sight by a huge URL).
    /// curl, the scripts, the sibling apps and the tablet over USB send none.
    static func looksLikeAWebPage(request raw: String, port: UInt16) -> Bool {
        guard raw.contains("\r\n\r\n") else { return true }
        let own: Set<String> = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
        let origin = header("origin", inRequest: raw)?.lowercased()
        let fromExtension = origin?.hasPrefix("chrome-extension://") == true
        if let origin, !fromExtension, !own.contains(origin) { return true }
        if let site = header("sec-fetch-site", inRequest: raw)?.lowercased(),
           site != "none", site != "same-origin", !fromExtension { return true }
        if let host = header("host", inRequest: raw)?.lowercased() {
            let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)",
                                      "127.0.0.1", "localhost", "[::1]"]
            if !hosts.contains(host) { return true }
        }
        return false
    }

    /// 🔌 The two WebSocket ports (8765 daemon, 8766 Chrome extension) are bound
    /// to loopback, but a web page can still dial `ws://127.0.0.1:…`: WebSockets
    /// are not held back by CORS. A browser always states its `Origin`; the
    /// daemon is not a browser and sends none.
    static func webSocketOriginAllowed(_ origin: String?, extensionsAllowed: Bool) -> Bool {
        guard let origin = origin?.lowercased(), !origin.isEmpty else { return true }
        return extensionsAllowed && origin.hasPrefix("chrome-extension://")
    }

    /// Loopback-only WebSocket listener parameters with that origin check.
    static func loopbackWebSocketParameters(port: UInt16, extensionsAllowed: Bool) -> NWParameters {
        let params = NWParameters.tcp
        // SO_REUSEADDR: rebind across a lingering TIME_WAIT socket after a quick restart.
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(DispatchQueue.global(qos: .utility)) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            let ok = webSocketOriginAllowed(origin, extensionsAllowed: extensionsAllowed)
            if !ok { overlayInfo("🚫 refused a WebSocket from \(origin ?? "?") on :\(port)") }
            return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    /// 📁 A path a `/test/*` route may WRITE to: only under the temp folders.
    /// These routes took any path, and a file written to `~/.zshenv` runs in the
    /// next shell. Symlinks are resolved first, so a link in /tmp cannot point out.
    static func scratchPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "..", name != "." else { return nil }
        let full = (parent as NSString).appendingPathComponent(name)
        var isLink = false
        if let t = try? FileManager.default.attributesOfItem(atPath: full)[.type] as? FileAttributeType {
            isLink = t == .typeSymbolicLink
        }
        let roots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        guard !isLink, roots.contains(where: { full.hasPrefix($0) }) else { return nil }
        return full
    }

    /// 🔗 What `/open` may hand to Chrome: a real http(s) URL. The string becomes
    /// an argv of the browser, so `--remote-debugging-port=…` or `file:///…`
    /// must never get there.
    static func webURL(_ text: String?) -> String? {
        guard let text, let c = URLComponents(string: text),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        return text
    }

    static func presentedToken(inRequest raw: String) -> String? {
        let head = raw.components(separatedBy: "\r\n\r\n").first ?? raw
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].lowercased() == "x-lan-token" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Takes the same time wherever the two differ.
    static func tokenMatches(_ presented: String?, expected: String?) -> Bool {
        guard let presented, let expected, presented.utf8.count == expected.utf8.count else { return false }
        return zip(presented.utf8, expected.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static let exact: Set<String> = ["/ping", "/tiles", "/usage", "/videos",
                                             "/alarm", "/bt-compensation", "/voice/level"]
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
    /// 🎙️ What the Railway relay may carry: every tablet route **but the voice
    /// meter's**. `/voice/level` is polled four times a second during a share;
    /// over the internet that is a stream of the room's loudness through a
    /// third-party host, and its latency would make the strip lie anyway. The
    /// tablet never sends it there (`MacLink.getBodyFast`); this refuses it if
    /// a build ever did.
    static func relayMayCall(_ path: String) -> Bool {
        guard tabletMayCall(path), let pathOnly = URLComponents(string: "http://x" + path)?.path else { return false }
        return !pathOnly.hasPrefix("/voice/")
    }

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
