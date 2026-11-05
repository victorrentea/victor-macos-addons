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
}
