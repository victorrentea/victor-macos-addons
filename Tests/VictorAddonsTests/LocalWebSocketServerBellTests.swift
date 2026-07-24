import XCTest
@testable import VictorAddons

/// Hermetic tests for the `bell_ring` message handling on the local WS server:
/// caller parsing (present / missing / empty), end-to-end dispatch to
/// `onBellRing` on the main thread, and that adding `bell_ring` leaves the other
/// message types (and the unknown-type log-and-ignore fallback) untouched.
final class LocalWebSocketServerBellTests: XCTestCase {

    // MARK: - Pure parsing (LocalWebSocketServer.bellCaller)

    func testBellCallerReadsPresentName() {
        XCTAssertEqual(LocalWebSocketServer.bellCaller(from: ["caller": "Ana Pop"]), "Ana Pop")
    }

    func testBellCallerFallsBackWhenMissing() {
        XCTAssertEqual(LocalWebSocketServer.bellCaller(from: [:]), "Someone")
    }

    func testBellCallerFallsBackWhenEmptyOrWhitespace() {
        XCTAssertEqual(LocalWebSocketServer.bellCaller(from: ["caller": ""]), "Someone")
        XCTAssertEqual(LocalWebSocketServer.bellCaller(from: ["caller": "   "]), "Someone")
    }

    func testBellCallerTrimsSurroundingWhitespace() {
        XCTAssertEqual(LocalWebSocketServer.bellCaller(from: ["caller": "  Dan  "]), "Dan")
    }

    // MARK: - End-to-end dispatch through handleText

    func testBellRingJsonInvokesOnBellRingWithCaller() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onBellRing fires")
        var received: String?
        server.onBellRing = { caller in
            received = caller
            expect.fulfill()
        }
        server.handleText(#"{"type":"bell_ring","caller":"Ana Pop"}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received, "Ana Pop")
    }

    func testBellRingWithoutCallerInvokesOnBellRingWithFallback() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onBellRing fires with fallback")
        var received: String?
        server.onBellRing = { caller in
            received = caller
            expect.fulfill()
        }
        server.handleText(#"{"type":"bell_ring"}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received, "Someone")
    }

    // MARK: - Additivity: bell_ring must not disturb existing handling

    func testMalformedJsonDoesNotFireBellRing() {
        let server = LocalWebSocketServer()
        var fired = false
        server.onBellRing = { _ in fired = true }
        // Non-JSON and an unknown type must both be silently ignored (log-only),
        // never firing the bell callback.
        server.handleText("not json at all", from: UUID())
        server.handleText(#"{"type":"totally_unknown"}"#, from: UUID())
        // Give any (incorrectly) scheduled main-queue dispatch a chance to run.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        XCTAssertFalse(fired, "bell_ring callback must not fire for malformed/unknown messages")
    }

    func testDisplayEmojiStillDispatchedAfterBellSupport() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onEmoji fires")
        var emoji: String?
        server.onEmoji = { e, _, _ in
            emoji = e
            expect.fulfill()
        }
        server.handleText(#"{"type":"display_emoji","emoji":"👍","count":1}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(emoji, "👍")
    }
}
