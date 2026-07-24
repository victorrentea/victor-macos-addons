import AppKit
import XCTest
@testable import VictorAddons

/// Hermetic tests for the `BellCard` controller. The controller is built with a
/// screens provider that returns `[]`, so `BottomLeftBanner` renders no panels
/// (no window server needed) — the tests assert the observable controller state
/// (the caller stack + card wording), leaving the actual on-screen rendering to
/// the manual `/test/bell` GUI check.
final class BellCardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // `BottomLeftBanner.show()` reads `NSApp.effectiveAppearance` to resolve
        // its light/dark palette; ensure the shared application exists so that
        // implicitly-unwrapped `NSApp` is non-nil in this headless test process.
        _ = NSApplication.shared
    }

    private func makeCard() -> BellCard {
        let card = BellCard(screensProvider: { [] })
        // Mute the chime: these tests assert controller state, and no other
        // suite makes the test machine audibly ding on every run.
        card.playChime = {}
        return card
    }

    // MARK: - Card copy (pure)

    func testCardTextSingleCallerMatchesExactWording() {
        XCTAssertEqual(BellCard.cardText(callers: ["Ana Pop"]), "🔔 Ana Pop is calling you")
    }

    func testCardTextMultipleCallersCoalesceWithArePlural() {
        XCTAssertEqual(BellCard.cardText(callers: ["Ana", "Dan"]), "🔔 Ana + Dan are calling you")
        XCTAssertEqual(BellCard.cardText(callers: ["Ana", "Dan", "Eve"]), "🔔 Ana + Dan + Eve are calling you")
    }

    func testCardTextEmptyListStaysTotalWithNeutralName() {
        // Unreachable via show() (addCaller guarantees ≥ 1), but the pure
        // function stays total — never the garbled "🔔  are calling you".
        XCTAssertEqual(BellCard.cardText(callers: []), "🔔 Someone is calling you")
    }

    // MARK: - Anonymous marker (BellCard.callerLabel + show(anonymous:))

    func testCallerLabelAppendsMarkerWhenAnonymous() {
        XCTAssertEqual(BellCard.callerLabel("Ana", anonymous: true), "Ana (anonymous)")
    }

    func testCallerLabelNoMarkerWhenNotAnonymous() {
        XCTAssertEqual(BellCard.callerLabel("Ana", anonymous: false), "Ana")
    }

    func testCallerLabelBlankAnonymousUsesNeutralName() {
        XCTAssertEqual(BellCard.callerLabel("   ", anonymous: true), "Someone (anonymous)")
    }

    func testAnonymousBellRendersMarkerInCardText() {
        let card = makeCard()
        card.show(caller: "Ana", anonymous: true)
        XCTAssertEqual(card.callers, ["Ana (anonymous)"])
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Ana (anonymous) is calling you")
    }

    func testNonAnonymousBellHasNoMarker() {
        let card = makeCard()
        card.show(caller: "Ana", anonymous: false)
        XCTAssertEqual(card.callers, ["Ana"])
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Ana is calling you")
    }

    func testAnonymousDefaultsFalseWhenFlagOmitted() {
        // The pre-flag call site — show(caller:) with no anonymous argument —
        // must behave exactly as today (no marker).
        let card = makeCard()
        card.show(caller: "Ana")
        XCTAssertEqual(card.callers, ["Ana"])
    }

    func testAnonymousAndNamedCallersCoalesce() {
        // Coalescing still works with a marked label mixed in.
        let card = makeCard()
        card.show(caller: "Ana", anonymous: true)
        card.show(caller: "Dan")
        XCTAssertEqual(card.callers, ["Ana (anonymous)", "Dan"])
        XCTAssertEqual(BellCard.cardText(callers: card.callers),
                       "🔔 Ana (anonymous) + Dan are calling you")
    }

    // MARK: - Stacking / de-dup / cap (BellCard.addCaller)

    func testSecondBellDoesNotOverwriteTheFirst() {
        let card = makeCard()
        card.show(caller: "Ana")
        card.show(caller: "Dan")
        // Both callers stay represented — the second bell must not replace the
        // first. (The coalesced wording itself is covered by the cardText tests.)
        XCTAssertEqual(card.callers, ["Ana", "Dan"])
    }

    func testRepeatBellFromSameCallerIsDeDuped() {
        let card = makeCard()
        card.show(caller: "Ana")
        card.show(caller: "Ana")
        XCTAssertEqual(card.callers, ["Ana"], "a repeat ring from the same caller must not duplicate the name")
    }

    func testStackIsCappedDroppingOldest() {
        let card = makeCard()
        card.show(caller: "Ana")
        card.show(caller: "Dan")
        card.show(caller: "Eve")
        card.show(caller: "Ben")   // exceeds the cap of 3 → oldest (Ana) drops off
        XCTAssertEqual(card.callers, ["Dan", "Eve", "Ben"])
        XCTAssertEqual(card.callers.count, BellCard.maxCallers)
    }

    func testEmptyCallerFallsBackToNeutralName() {
        let card = makeCard()
        card.show(caller: "   ")
        XCTAssertEqual(card.callers, ["Someone"])
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Someone is calling you")
    }

    // MARK: - Persistence + hover dismiss

    func testCardIsPersistentNoAutoFade() {
        let card = makeCard()
        card.show(caller: "Ana")
        // No auto-dismiss timer exists: after draining the main queue the caller
        // stack is still present (a card would only clear on an explicit dismiss).
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        XCTAssertEqual(card.callers, ["Ana"], "the card must persist — nothing clears it on a timer")
    }

    func testDismissClearsTheStack() {
        let card = makeCard()
        card.show(caller: "Ana")
        card.show(caller: "Dan")
        card.dismiss()
        XCTAssertTrue(card.callers.isEmpty, "hover-dismiss acknowledges all callers and clears the stack")
    }
}
