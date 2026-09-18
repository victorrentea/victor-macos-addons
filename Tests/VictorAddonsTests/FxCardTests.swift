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

    // MARK: - End-to-end dispatch through handleText

    func testFxFiredJsonInvokesOnFxFiredWithLabel() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires")
        var received: String?
        server.onFxFired = { label in
            received = label
            expect.fulfill()
        }
        server.handleText(#"{"type":"fx_fired","tile_n":69,"label":"scream ghost"}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received, "scream ghost")
    }

    func testFxFiredWithoutLabelInvokesOnFxFiredWithFallback() {
        let server = LocalWebSocketServer()
        let expect = expectation(description: "onFxFired fires with fallback")
        var received: String?
        server.onFxFired = { label in
            received = label
            expect.fulfill()
        }
        server.handleText(#"{"type":"fx_fired"}"#, from: UUID())
        wait(for: [expect], timeout: 1.0)
        XCTAssertEqual(received, "a sound effect")
    }

    // MARK: - Additivity: fx_fired must not disturb existing handling

    func testMalformedJsonDoesNotFireFx() {
        let server = LocalWebSocketServer()
        var fired = false
        server.onFxFired = { _ in fired = true }
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
        server.onFxFired = { _ in fxFired = true }
        server.onBellRing = { _, _ in bellFired = true }

        let bellSeen = expectation(description: "bell dispatched")
        server.onBellRing = { _, _ in bellFired = true; bellSeen.fulfill() }
        server.handleText(#"{"type":"bell_ring","caller":"Ana"}"#, from: UUID())
        wait(for: [bellSeen], timeout: 1.0)
        XCTAssertTrue(bellFired)
        XCTAssertFalse(fxFired, "a bell must not raise the FX tab")

        bellFired = false
        let fxSeen = expectation(description: "fx dispatched")
        server.onFxFired = { _ in fxFired = true; fxSeen.fulfill() }
        server.handleText(#"{"type":"fx_fired","label":"wazzup"}"#, from: UUID())
        wait(for: [fxSeen], timeout: 1.0)
        XCTAssertTrue(fxFired)
        XCTAssertFalse(bellFired, "an FX press must not raise the bell tab")
    }

    // MARK: - Card copy and state

    func testCardTextIsGlyphPlusLabel() {
        XCTAssertEqual(FxCard.cardText(label: "scream ghost"), "🔴 scream ghost")
    }

    func testCardTextFallsBackOnBlankLabel() {
        XCTAssertEqual(FxCard.cardText(label: "   "), "🔴 a sound effect")
    }

    func testShowRecordsLatestLabelOnly() {
        // Latest-wins: unlike the bell there is no list to grow — the link is
        // anonymous, so a second press is the same holder, not a second person.
        let card = FxCard(screensProvider: { [] })
        card.show(label: "scream ghost")
        XCTAssertEqual(card.label, "scream ghost")
        card.show(label: "wazzup")
        XCTAssertEqual(card.label, "wazzup")
    }

    func testShowNormalizesBlankLabel() {
        let card = FxCard(screensProvider: { [] })
        card.show(label: "  ")
        XCTAssertEqual(card.label, "a sound effect")
    }

    func testDismissClearsTheLabel() {
        // `BottomTabBanner.dismiss()` fires `onDismissed` even with nothing
        // rendered, which is what makes the state consistent headlessly.
        let card = FxCard(screensProvider: { [] })
        card.show(label: "scream ghost")
        card.dismiss()
        XCTAssertNil(card.label)
    }
}
