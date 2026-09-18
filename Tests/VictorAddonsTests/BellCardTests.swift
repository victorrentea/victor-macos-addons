import AppKit
import XCTest
@testable import VictorAddons

/// Hermetic tests for the `BellCard` controller. The controller is built with a
/// screens provider that returns `[]`, so `BottomTabBanner` renders no panels
/// (no window server needed) — the tests assert the observable controller state
/// (the caller stack + tab wording), leaving the actual on-screen rendering to
/// the manual `/test/bell` GUI check.
final class BellCardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The banner touches AppKit on show(); ensure the shared application
        // exists so implicitly-unwrapped `NSApp` is non-nil in this headless
        // test process.
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
        XCTAssertEqual(BellCard.cardText(callers: ["Ana Pop"]), "🔔 Ana Pop")
    }

    func testCardTextMultipleCallersCoalesceWithPlusSigns() {
        XCTAssertEqual(BellCard.cardText(callers: ["Ana", "Dan"]), "🔔 Ana + Dan")
        XCTAssertEqual(BellCard.cardText(callers: ["Ana", "Dan", "Eve"]), "🔔 Ana + Dan + Eve")
    }

    func testCardTextEmptyListStaysTotalWithNeutralName() {
        // Unreachable via show() (addCaller guarantees ≥ 1), but the pure
        // function stays total — never a bare bell with no name after it.
        XCTAssertEqual(BellCard.cardText(callers: []), "🔔 Someone")
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
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Ana (anonymous)")
    }

    func testNonAnonymousBellHasNoMarker() {
        let card = makeCard()
        card.show(caller: "Ana", anonymous: false)
        XCTAssertEqual(card.callers, ["Ana"])
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Ana")
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
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Ana (anonymous) + Dan")
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
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Someone")
    }

    // MARK: - Transience

    func testDismissClearsTheStack() {
        // The tab announces and leaves; whoever it named is forgotten with it, so
        // the next bell starts a fresh announcement rather than resurrecting
        // names nobody can still see. (On screen the clear is driven by the
        // banner's onDismissed once the tab has finished falling.)
        let card = makeCard()
        card.show(caller: "Ana")
        card.show(caller: "Dan")
        card.dismiss()
        XCTAssertTrue(card.callers.isEmpty)
    }

    func testCallersSurviveUntilTheTabActuallyLeaves() {
        // Nothing clears the stack on the main queue alone — a second bell
        // arriving in the same breath must still find the first caller there to
        // coalesce with.
        let card = makeCard()
        card.show(caller: "Ana")
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
        XCTAssertEqual(card.callers, ["Ana"])
    }
}
