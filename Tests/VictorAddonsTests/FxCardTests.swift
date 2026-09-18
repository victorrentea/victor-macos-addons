import XCTest
@testable import VictorAddons

/// Hermetic tests for the 🔴 FX announcement: the `fx_fired` message handling on
/// the local WS server (label parsing, dispatch, additivity) and `FxCard`'s own
/// copy and latest-wins state. No panels are built — these run headlessly, where
/// `BottomTabBanner` has no screens to render on.
final class FxCardTests: XCTestCase {

    // MARK: - Pure parsing (LocalWebSocketServer.fxLabel)

    func testFxLabelReadsPresentLabel() {
        XCTAssertEqual(LocalWebSocketServer.fxLabel(from: ["label": "scream ghost"]), "scream ghost")
    }

    func testFxLabelFallsBackWhenMissing() {
        XCTAssertEqual(LocalWebSocketServer.fxLabel(from: [:]), "a sound effect")
    }

    func testFxLabelFallsBackWhenEmptyOrWhitespace() {
        XCTAssertEqual(LocalWebSocketServer.fxLabel(from: ["label": ""]), "a sound effect")
        XCTAssertEqual(LocalWebSocketServer.fxLabel(from: ["label": "   "]), "a sound effect")
    }

    func testFxLabelTrimsSurroundingWhitespace() {
        XCTAssertEqual(LocalWebSocketServer.fxLabel(from: ["label": "  wazzup  "]), "wazzup")
    }

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

    func testFxAnonymousDefaultsFalseWhenAbsentOrNotABool() {
        XCTAssertTrue(LocalWebSocketServer.fxAnonymous(from: ["anonymous": true]))
        XCTAssertFalse(LocalWebSocketServer.fxAnonymous(from: [:]))
        XCTAssertFalse(LocalWebSocketServer.fxAnonymous(from: ["anonymous": "yes"]))
    }

    // MARK: - End-to-end dispatch through handleText

    func testFxFiredJsonInvokesOnFxFiredWithLabelAndCaller() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires")
        var received: (String, String, Bool)?
        server.onFxFired = { label, caller, anonymous in
            received = (label, caller, anonymous)
            expect.fulfill()
        }
        server.handleText(
            #"{"type":"fx_fired","tile_n":69,"label":"scream ghost","caller":"Ana Pop","anonymous":false}"#,
            from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received?.0, "scream ghost")
        XCTAssertEqual(received?.1, "Ana Pop")
        XCTAssertEqual(received?.2, false)
    }

    func testFxFiredCarriesTheAnonymousFlag() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires anonymous")
        var anon: Bool?
        server.onFxFired = { _, _, anonymous in
            anon = anonymous
            expect.fulfill()
        }
        server.handleText(
            #"{"type":"fx_fired","label":"wazzup","caller":"Dan","anonymous":true}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(anon, true)
    }

    func testFxFiredWithoutLabelOrCallerInvokesOnFxFiredWithFallbacks() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires with fallbacks")
        var received: (String, String, Bool)?
        server.onFxFired = { label, caller, anonymous in
            received = (label, caller, anonymous)
            expect.fulfill()
        }
        server.handleText(#"{"type":"fx_fired"}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received?.0, "a sound effect")
        XCTAssertEqual(received?.1, "Someone")
        XCTAssertEqual(received?.2, false)
    }

    // MARK: - Additivity: fx_fired must not disturb existing handling

    func testMalformedJsonDoesNotFireFx() {
        let server = LocalWebSocketServer()
        var fired = false
        server.onFxFired = { _, _, _ in fired = true }
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
        server.onFxFired = { _, _, _ in fxFired = true }
        server.onBellRing = { _, _ in bellFired = true }

        let bellSeen = expectation(description: "bell dispatched")
        server.onBellRing = { _, _ in bellFired = true; bellSeen.fulfill() }
        server.handleText(#"{"type":"bell_ring","caller":"Ana"}"#, from: UUID())
        wait(for: [bellSeen], timeout: 1.0)
        XCTAssertTrue(bellFired)
        XCTAssertFalse(fxFired, "a bell must not raise the FX tab")

        bellFired = false
        let fxSeen = expectation(description: "fx dispatched")
        server.onFxFired = { _, _, _ in fxFired = true; fxSeen.fulfill() }
        server.handleText(#"{"type":"fx_fired","label":"wazzup"}"#, from: UUID())
        wait(for: [fxSeen], timeout: 1.0)
        XCTAssertTrue(fxFired)
        XCTAssertFalse(bellFired, "an FX press must not raise the bell tab")
    }

    // MARK: - Card copy and state

    func testCardTextIsGlyphNameAndTile() {
        XCTAssertEqual(FxCard.cardText(caller: "Ana Pop", label: "scream ghost"),
                       "🔴 Ana Pop · scream ghost")
    }

    func testCardTextFallsBackOnBlankInputs() {
        XCTAssertEqual(FxCard.cardText(caller: "  ", label: "   "),
                       "🔴 Someone · a sound effect")
    }

    func testAnonymousPresserIsMarkedExactlyAsTheBellMarksOne() {
        // One wording for the marker across both tabs — the reason
        // `BellCard.callerLabel` is shared rather than re-spelled here.
        let card = FxCard(screensProvider: { [] })
        card.show(label: "scream ghost", caller: "Ana Pop", anonymous: true)
        XCTAssertEqual(card.announcement?.caller,
                       BellCard.callerLabel("Ana Pop", anonymous: true))
        XCTAssertEqual(card.announcement?.caller, "Ana Pop (anonymous)")
    }

    func testShowRecordsLatestAnnouncementOnly() {
        // Latest-wins: unlike the bell there is no list to grow — one link, one
        // holder, so a second press replaces rather than joins.
        let card = FxCard(screensProvider: { [] })
        card.show(label: "scream ghost", caller: "Ana Pop")
        XCTAssertEqual(card.announcement?.caller, "Ana Pop")
        XCTAssertEqual(card.announcement?.label, "scream ghost")
        card.show(label: "wazzup", caller: "Dan")
        XCTAssertEqual(card.announcement?.caller, "Dan")
        XCTAssertEqual(card.announcement?.label, "wazzup")
    }

    func testShowNormalizesBlankInputs() {
        let card = FxCard(screensProvider: { [] })
        card.show(label: "  ", caller: " ")
        XCTAssertEqual(card.announcement?.caller, "Someone")
        XCTAssertEqual(card.announcement?.label, "a sound effect")
    }

    func testAPresserWithoutANameNeverShowsAUuid() {
        // The daemon resolves the name and never puts a UUID on the wire; this
        // is the overlay's own half of that guarantee.
        let card = FxCard(screensProvider: { [] })
        card.show(label: "scream ghost", caller: "Someone")
        XCTAssertEqual(FxCard.cardText(caller: card.announcement!.caller,
                                       label: card.announcement!.label),
                       "🔴 Someone · scream ghost")
    }

    func testDismissClearsTheAnnouncement() {
        // `BottomTabBanner.dismiss()` fires `onDismissed` even with nothing
        // rendered, which is what makes the state consistent headlessly.
        let card = FxCard(screensProvider: { [] })
        card.show(label: "scream ghost", caller: "Ana Pop")
        card.dismiss()
        XCTAssertNil(card.announcement)
    }
}
