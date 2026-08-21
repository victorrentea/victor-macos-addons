import XCTest
@testable import VictorAddons

final class HandsOffSessionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func session(agent: String? = "codex",
                         what: String? = "click pe Restart to Update",
                         ttl: TimeInterval? = 60) -> HandsOffSession {
        HandsOffSession(agent: agent, what: what, ttl: ttl, startedAt: t0)
    }

    // MARK: - Label

    func testLabelCarriesAgentAndWhat() {
        XCTAssertEqual(session().label, "✋ codex — click pe Restart to Update")
    }

    /// An agent that says only who it is still gets a badge: the palm is the
    /// message, the words are the detail.
    func testLabelWithoutWhatIsJustTheAgent() {
        XCTAssertEqual(session(what: nil).label, "✋ codex")
        XCTAssertEqual(session(what: "   ").label, "✋ codex")
    }

    /// A caller that forgets `?agent=` must not produce "✋  — doing a thing":
    /// the badge has to read as a sentence even when the call is sloppy.
    func testMissingAgentFallsBackToGenericName() {
        XCTAssertEqual(session(agent: nil, what: "typing").label, "✋ agent — typing")
        XCTAssertEqual(session(agent: "  ", what: "typing").label, "✋ agent — typing")
    }

    func testAgentAndWhatAreTrimmed() {
        XCTAssertEqual(session(agent: " codex ", what: " typing ").label, "✋ codex — typing")
    }

    // MARK: - TTL

    func testDefaultTTLWhenUnspecified() {
        XCTAssertEqual(session(ttl: nil).ttl, HandsOffSession.defaultTTL)
    }

    /// A non-positive ttl is a caller bug, not a request to expire instantly —
    /// treating it literally would flash the frame and drop it before Victor's
    /// eye got there, which is worse than not showing it at all.
    func testNonPositiveTTLFallsBackToDefault() {
        XCTAssertEqual(session(ttl: 0).ttl, HandsOffSession.defaultTTL)
        XCTAssertEqual(session(ttl: -5).ttl, HandsOffSession.defaultTTL)
    }

    /// So a typo in `?ttl=` can't park the frame for an afternoon.
    func testTTLIsCappedAtMax() {
        XCTAssertEqual(session(ttl: 99_999).ttl, HandsOffSession.maxTTL)
    }

    // MARK: - Expiry

    func testNotExpiredBeforeTTL() {
        let s = session(ttl: 60)
        XCTAssertFalse(s.isExpired(at: t0))
        XCTAssertFalse(s.isExpired(at: t0.addingTimeInterval(59)))
    }

    func testExpiredAtAndAfterTTL() {
        let s = session(ttl: 60)
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(60)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(600)))
    }

    func testRemainingCountsDownAndFloorsAtZero() {
        let s = session(ttl: 60)
        XCTAssertEqual(s.remaining(at: t0), 60, accuracy: 0.001)
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(25)), 35, accuracy: 0.001)
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(9_999)), 0, accuracy: 0.001)
    }
}
