import XCTest
@testable import VictorAddons

/// Hermetic tests for the FX announcement: the `fx_fired` message handling on
/// the local WS server (presser parsing, dispatch, additivity) and `FxCard`'s own
/// copy and latest-wins state. No panels are built — these run headlessly, where
/// `BottomTabBanner` has no screens to render on.
final class FxCardTests: XCTestCase {

    // MARK: - Pure presser parsing (fxCaller / fxAnonymous)

    func testFxCallerReadsPresentName() {
        XCTAssertEqual(LocalWebSocketServer.fxCaller(from: ["caller": "Ana Pop"]), "Ana Pop")
    }

    func testFxCallerFallsBackWhenMissingOrBlank() {
        // A payload from a daemon predating the field must still announce the
        // press — just without a name.
        XCTAssertEqual(LocalWebSocketServer.fxCaller(from: [:]), "Someone")
        XCTAssertEqual(LocalWebSocketServer.fxCaller(from: ["caller": "   "]), "Someone")
    }

    func testFxCallerTrimsSurroundingWhitespace() {
        XCTAssertEqual(LocalWebSocketServer.fxCaller(from: ["caller": "  Dan  "]), "Dan")
    }

    func testFxAnonymousDefaultsFalseWhenAbsentOrNotABool() {
        XCTAssertTrue(LocalWebSocketServer.fxAnonymous(from: ["anonymous": true]))
        XCTAssertFalse(LocalWebSocketServer.fxAnonymous(from: [:]))
        XCTAssertFalse(LocalWebSocketServer.fxAnonymous(from: ["anonymous": "yes"]))
    }

    // MARK: - End-to-end dispatch through handleText

    func testFxFiredJsonInvokesOnFxFiredWithCaller() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires")
        var received: (String, Bool)?
        server.onFxFired = { caller, anonymous in
            received = (caller, anonymous)
            expect.fulfill()
        }
        server.handleText(
            #"{"type":"fx_fired","caller":"Ana Pop","anonymous":false}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received?.0, "Ana Pop")
        XCTAssertEqual(received?.1, false)
    }

    func testFxFiredCarriesTheAnonymousFlag() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires anonymous")
        var anon: Bool?
        server.onFxFired = { _, anonymous in
            anon = anonymous
            expect.fulfill()
        }
        server.handleText(#"{"type":"fx_fired","caller":"Dan","anonymous":true}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(anon, true)
    }

    func testFxFiredWithoutACallerInvokesOnFxFiredWithFallbacks() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires with fallbacks")
        var received: (String, Bool)?
        server.onFxFired = { caller, anonymous in
            received = (caller, anonymous)
            expect.fulfill()
        }
        server.handleText(#"{"type":"fx_fired"}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received?.0, "Someone")
        XCTAssertEqual(received?.1, false)
    }

    // MARK: - Additivity: fx_fired must not disturb existing handling

    func testMalformedJsonDoesNotFireFx() {
        let server = LocalWebSocketServer()
        var fired = false
        server.onFxFired = { _, _ in fired = true }
        server.handleText("not json at all", from: UUID())
        server.handleText(#"{"type":"totally_unknown"}"#, from: UUID())
        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1.0)
        XCTAssertFalse(fired)
    }

    func testBellRingDoesNotFireFxAndViceVersa() {
        // The two share a surface but not a message: neither may trigger the other.
        let server = LocalWebSocketServer()
        var fxFired = false
        var bellFired = false
        server.onFxFired = { _, _ in fxFired = true }
        server.onBellRing = { _, _ in bellFired = true }

        let bellSeen = expectation(description: "bell dispatched")
        server.onBellRing = { _, _ in bellFired = true; bellSeen.fulfill() }
        server.handleText(#"{"type":"bell_ring","caller":"Ana"}"#, from: UUID())
        wait(for: [bellSeen], timeout: 1.0)
        XCTAssertTrue(bellFired)
        XCTAssertFalse(fxFired, "a bell must not raise the FX tab")

        bellFired = false
        let fxSeen = expectation(description: "fx dispatched")
        server.onFxFired = { _, _ in fxFired = true; fxSeen.fulfill() }
        server.handleText(#"{"type":"fx_fired","caller":"Dan"}"#, from: UUID())
        wait(for: [fxSeen], timeout: 1.0)
        XCTAssertTrue(fxFired)
        XCTAssertFalse(bellFired, "an FX press must not raise the bell tab")
    }

    // MARK: - Card copy and state

    func testCardTextIsTheNameAndNothingElse() {
        // No glyph, no tile: the sound already said the rest.
        XCTAssertEqual(FxCard.cardText(caller: "Marc Sánchez"), "Marc Sánchez")
    }

    func testCardTextFallsBackOnABlankName() {
        XCTAssertEqual(FxCard.cardText(caller: "  "), "Someone")
    }

    func testAnonymousPresserIsMarkedExactlyAsTheBellMarksOne() {
        // One wording for the marker across both tabs — the reason
        // `BellCard.callerLabel` is shared rather than re-spelled here.
        let card = FxCard(screensProvider: { [] })
        card.show(caller: "Ana Pop", anonymous: true)
        XCTAssertEqual(card.caller, BellCard.callerLabel("Ana Pop", anonymous: true))
        XCTAssertEqual(card.caller, "Ana Pop (anonymous)")
    }

    func testShowRecordsLatestPresserOnly() {
        // Latest-wins: unlike the bell there is no list to grow — one link, one
        // holder, so a second press replaces rather than joins.
        let card = FxCard(screensProvider: { [] })
        card.show(caller: "Ana Pop")
        XCTAssertEqual(card.caller, "Ana Pop")
        card.show(caller: "Dan")
        XCTAssertEqual(card.caller, "Dan")
    }

    func testShowNormalizesABlankName() {
        let card = FxCard(screensProvider: { [] })
        card.show(caller: " ")
        XCTAssertEqual(card.caller, "Someone")
    }

    func testAPresserWithoutANameNeverShowsAUuid() {
        // The daemon resolves the name and never puts a UUID on the wire; this
        // is the overlay's own half of that guarantee.
        let card = FxCard(screensProvider: { [] })
        card.show(caller: "Someone")
        XCTAssertEqual(FxCard.cardText(caller: card.caller!), "Someone")
    }

    func testDismissClearsThePresser() {
        // `BottomTabBanner.dismiss()` fires `onDismissed` even with nothing
        // rendered, which is what makes the state consistent headlessly.
        let card = FxCard(screensProvider: { [] })
        card.show(caller: "Ana Pop")
        card.dismiss()
        XCTAssertNil(card.caller)
    }
}
