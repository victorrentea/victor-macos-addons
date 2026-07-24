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
        BellCard(screensProvider: { [] })
    }

    // MARK: - Card copy (pure)

    func testCardTextSingleCallerMatchesExactWording() {
        XCTAssertEqual(BellCard.cardText(callers: ["Ana Pop"]), "🔔 Ana Pop is calling you")
    }

    func testCardTextMultipleCallersCoalesceWithArePlural() {
        XCTAssertEqual(BellCard.cardText(callers: ["Ana", "Dan"]), "🔔 Ana + Dan are calling you")
        XCTAssertEqual(BellCard.cardText(callers: ["Ana", "Dan", "Eve"]), "🔔 Ana + Dan + Eve are calling you")
    }

    // MARK: - Stacking / de-dup / cap (BellCard.addCaller)

    func testSecondBellDoesNotOverwriteTheFirst() {
        let card = makeCard()
        card.show(caller: "Ana")
        card.show(caller: "Dan")
        // Both callers stay represented — the second bell must not replace the first.
        XCTAssertEqual(card.callers, ["Ana", "Dan"])
        XCTAssertEqual(BellCard.cardText(callers: card.callers), "🔔 Ana + Dan are calling you")
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
