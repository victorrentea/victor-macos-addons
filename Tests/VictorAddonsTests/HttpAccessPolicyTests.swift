import Network
import XCTest
@testable import VictorAddons

final class HttpAccessPolicyTests: XCTestCase {

    func testTheTabletsRoutesAreOpen() {
        for path in ["/ping", "/tiles", "/tiles/a.png", "/usage", "/usage/reset", "/videos",
                     "/video/stop", "/video/play/3?gain=50", "/sound/play/x.mp3?vol=80",
                     "/sounds/manifest", "/effect/stop-all", "/alarm", "/bt-compensation/120",
                     // Built from `MAC_ALARM_URL`, which the source scan below cannot see.
                     "/alarm/start", "/alarm/stop"] {
            XCTAssertTrue(HttpAccessPolicy.tabletMayCall(path), path)
        }
    }

    func testEverythingElseStaysOnThisMac() {
        for path in ["/test/email", "/test/screen-lock", "/test/focus-playlist",
                     "/open?url=http://evil.example", "/hands-off/start", "/link/publish",
                     "/session/name", "/training/prompt-capture", "/feedback-form/publish",
                     "/mirror/exclusions", "/press/1", "/state", "/brand-new-route", "/", ""] {
            XCTAssertFalse(HttpAccessPolicy.tabletMayCall(path), path)
        }
    }

    func testAnAllowedPrefixCannotBeWalkedOutOf() {
        for path in ["/sound/../test/email", "/tiles/../open", "/video/%2e%2e/test/email",
                     "/effect/./x", "//test/email", "/pingpong", "/videos/x"] {
            XCTAssertFalse(HttpAccessPolicy.tabletMayCall(path), path)
        }
    }

    func testOnlyLoopbackIsLocal() {
        func peer(_ host: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: 1234) }
        XCTAssertTrue(HttpAccessPolicy.isLocal(peer("127.0.0.1")))
        XCTAssertTrue(HttpAccessPolicy.isLocal(peer("::1")))
        XCTAssertTrue(HttpAccessPolicy.isLocal(peer("::ffff:127.0.0.1")))
        XCTAssertFalse(HttpAccessPolicy.isLocal(peer("192.168.1.9")))
        XCTAssertFalse(HttpAccessPolicy.isLocal(peer("::ffff:192.168.1.9")))
        XCTAssertFalse(HttpAccessPolicy.isLocal(peer("fe80::1")))
        XCTAssertFalse(HttpAccessPolicy.isLocal(peer("victor-mac.local")))
    }

    func testTheNetworkDecision() {
        typealias P = HttpAccessPolicy
        // Until the tablet has shown a token, a tablet route needs none: an older
        // build would otherwise lose its Wi-Fi link.
        XCTAssertEqual(P.decide(path: "/ping", local: false, tokenValid: false, armed: false), .serve)
        XCTAssertEqual(P.decide(path: "/ping", local: false, tokenValid: false, armed: true), .tokenRefused)
        XCTAssertEqual(P.decide(path: "/ping", local: false, tokenValid: true, armed: true), .serve)
        // The token never widens the list.
        XCTAssertEqual(P.decide(path: "/test/email", local: false, tokenValid: true, armed: true), .routeRefused)
        XCTAssertEqual(P.decide(path: "/test/email", local: false, tokenValid: false, armed: false), .routeRefused)
        // This Mac, and USB through adb reverse, never need it.
        XCTAssertEqual(P.decide(path: "/test/email", local: true, tokenValid: false, armed: true), .serve)
    }

    /// The same value is pinned in the tablet's `LanTokenTest`.
    func testDerivesWhatTheTabletSends() {
        XCTAssertEqual(HttpAccessPolicy.lanToken(fromBridgeToken: "test-token"),
                       "ab42c7d8f2b4831553c735a1d5c054e0b4676e79a32989fc6cf0a450503c4e87")
    }

    func testNoRelayTokenMeansNoLanTokenAndNothingMatches() {
        XCTAssertNil(HttpAccessPolicy.lanToken(fromBridgeToken: ""))
        XCTAssertFalse(HttpAccessPolicy.tokenMatches("", expected: nil))
        XCTAssertFalse(HttpAccessPolicy.tokenMatches(nil, expected: nil))
    }

    func testTokenComparison() {
        XCTAssertTrue(HttpAccessPolicy.tokenMatches("abc", expected: "abc"))
        XCTAssertFalse(HttpAccessPolicy.tokenMatches("abd", expected: "abc"))
        XCTAssertFalse(HttpAccessPolicy.tokenMatches("ab", expected: "abc"))
        XCTAssertFalse(HttpAccessPolicy.tokenMatches(nil, expected: "abc"))
    }

    func testReadsTheTokenFromTheHeadOnly() {
        let request = "GET /ping HTTP/1.1\r\nHost: x\r\nX-LAN-Token:  abc \r\n\r\nbody"
        XCTAssertEqual(HttpAccessPolicy.presentedToken(inRequest: request), "abc")
        XCTAssertNil(HttpAccessPolicy.presentedToken(inRequest: "GET / HTTP/1.1\r\nHost: x\r\n\r\nX-Lan-Token: abc"))
        XCTAssertNil(HttpAccessPolicy.presentedToken(inRequest: "X-Lan-Token: abc /ping HTTP/1.1\r\n\r\n"))
    }

    /// A new tablet route would work on the cable and answer 403 on Wi-Fi, which
    /// is exactly the bug nobody finds at the desk.
    func testEveryRouteTheTabletCallsIsOpen() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("victor-vibe-board/app/src/main/java/ro/victorrentea/helloworld")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sources.path) else {
            throw XCTSkip("victor-vibe-board is not checked out beside this repo")
        }
        let literal = try NSRegularExpression(pattern: #""(?:\$MAC_BASE_URL)?(/[a-z][a-z-]*[^"$?]*)"#)
        var routes = Set<String>()
        for name in names where name.hasSuffix(".kt") {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { routes.insert(String(text[range])) }
            }
        }
        XCTAssertTrue(routes.contains("/ping"), "the pattern no longer finds the tablet's routes")
        let notRoutes: Set<String> = ["/ws/bridge/tablet"]   // the relay's own socket
        let closed = routes.subtracting(notRoutes).filter { !HttpAccessPolicy.tabletMayCall($0) }
        XCTAssertEqual(closed.sorted(), [], "add it to HttpAccessPolicy, or it answers 403 over Wi-Fi")
    }

    // MARK: - 2026-11-13 security review: loopback is not "me"

    private func request(_ headers: [String]) -> String {
        (["GET /test/state HTTP/1.1"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
    }

    func testScriptsAndSiblingAppsAreNotTakenForAWebPage() {
        XCTAssertFalse(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: 127.0.0.1:55123", "User-Agent: curl/8"]), port: 55123))
        XCTAssertFalse(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: localhost:55123"]), port: 55123))
        XCTAssertFalse(HttpAccessPolicy.looksLikeAWebPage(request: request([]), port: 55123))
        // typed in the address bar
        XCTAssertFalse(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: 127.0.0.1:55123", "Sec-Fetch-Site: none"]), port: 55123))
        // our own Chrome extension's service worker
        XCTAssertFalse(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: 127.0.0.1:55123", "Origin: chrome-extension://abc", "Sec-Fetch-Site: cross-site"]), port: 55123))
    }

    func testAWebPageOnLoopbackIsRecognised() {
        XCTAssertTrue(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: 127.0.0.1:55123", "Origin: https://evil.example"]), port: 55123))
        // <img src> and a navigated popup carry no Origin, only this
        XCTAssertTrue(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: 127.0.0.1:55123", "Sec-Fetch-Site: cross-site"]), port: 55123))
        XCTAssertTrue(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: 127.0.0.1:55123", "Sec-Fetch-Site: same-site"]), port: 55123))
        // DNS rebinding: the page's own name resolves to 127.0.0.1
        XCTAssertTrue(HttpAccessPolicy.looksLikeAWebPage(request: request(["Host: evil.example:55123"]), port: 55123))
        // a head that did not fit the first read hides its headers
        XCTAssertTrue(HttpAccessPolicy.looksLikeAWebPage(request: "GET /x HTTP/1.1\r\nHost: 127.0.0.1:55123\r\n", port: 55123))
    }

    func testTestRoutesWriteOnlyUnderTheTempFolders() {
        XCTAssertNotNil(HttpAccessPolicy.scratchPath("/tmp/m"))
        XCTAssertNotNil(HttpAccessPolicy.scratchPath(NSTemporaryDirectory() + "x.png"))
        XCTAssertNil(HttpAccessPolicy.scratchPath(NSHomeDirectory() + "/.zshenv"))
        XCTAssertNil(HttpAccessPolicy.scratchPath("/tmp/../Users/x/.zshenv"))
        XCTAssertNil(HttpAccessPolicy.scratchPath("relative.png"))
        XCTAssertNil(HttpAccessPolicy.scratchPath(nil))
        let link = NSTemporaryDirectory() + "policy-link-\(UUID().uuidString)"
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: NSHomeDirectory())
        defer { try? FileManager.default.removeItem(atPath: link) }
        XCTAssertNil(HttpAccessPolicy.scratchPath(link + "/.zshenv"), "a link in /tmp must not lead out")
        XCTAssertNil(HttpAccessPolicy.scratchPath(link), "nor be overwritten through")
    }

    func testAMarkerOutsideTempIsNotARoute() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/hands-off/takeover?marker=/Users/x/.zshenv"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/hands-off/render?out=/Users/x/.zshrc"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/hands-off/click?corner=bl&marker=/Users/x/.zshenv"), .unknown)
    }

    func testOpenTakesOnlyWebURLs() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/open?url=https://victorrentea.ro/x"), .openUrl("https://victorrentea.ro/x"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/open?url=--remote-debugging-port%3D9222"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/open?url=file:///etc/passwd"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/open?url=chrome://settings"), .unknown)
    }

    func testOnlyANonBrowserOrAnExtensionOpensTheWebSockets() {
        XCTAssertTrue(HttpAccessPolicy.webSocketOriginAllowed(nil, extensionsAllowed: false))
        XCTAssertFalse(HttpAccessPolicy.webSocketOriginAllowed("https://evil.example", extensionsAllowed: true))
        XCTAssertFalse(HttpAccessPolicy.webSocketOriginAllowed("chrome-extension://abc", extensionsAllowed: false))
        XCTAssertTrue(HttpAccessPolicy.webSocketOriginAllowed("chrome-extension://abc", extensionsAllowed: true))
    }
}
