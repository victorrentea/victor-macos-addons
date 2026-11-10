import XCTest
@testable import VictorAddons

final class BottomLeftStackPolicyTests: XCTestCase {
    private typealias P = BottomLeftStackPolicy

    func testFirstPillTakesTheBottomSlot() {
        let r = P.arrive("a", into: [])
        XCTAssertEqual(r.order, ["a"])
        XCTAssertEqual(r.evicted, [])
    }

    func testSecondPillEntersBelowAndPushesTheFirstUp() {
        let r = P.arrive("b", into: ["a"])
        XCTAssertEqual(r.order, ["b", "a"], "bottom first: the newcomer at the bottom")
        XCTAssertEqual(r.evicted, [])
    }

    func testThirdPillPushesTheTopOneOut() {
        let r = P.arrive("c", into: ["b", "a"])
        XCTAssertEqual(r.order, ["c", "b"], "never more than two up")
        XCTAssertEqual(r.evicted, ["a"], "the oldest, on top, leaves")
    }

    func testAPillAlreadyUpThatArrivesAgainMovesToTheBottomWithoutDuplicating() {
        let r = P.arrive("a", into: ["b", "a"])
        XCTAssertEqual(r.order, ["a", "b"])
        XCTAssertEqual(r.evicted, [])
    }

    func testAPinnedAlarmOnTopStaysAndTheOldestUnpinnedLeavesInstead() {
        let r = P.arrive("c", into: ["b", "alarm"], pinned: { $0 == "alarm" })
        XCTAssertEqual(r.order, ["c", "alarm"])
        XCTAssertEqual(r.evicted, ["b"])
    }

    func testTwoPinnedAlarmsLetTheStackGrowRatherThanLoseOne() {
        let r = P.arrive("c", into: ["a1", "a2"], pinned: { $0.hasPrefix("a") })
        XCTAssertEqual(r.order, ["c", "a1", "a2"])
        XCTAssertEqual(r.evicted, [])
    }

    func testThePinnedNewcomerIsNeverTheOnePushedOut() {
        let r = P.arrive("new", into: ["b", "a"], pinned: { _ in true })
        XCTAssertEqual(r.order, ["new", "b", "a"])
    }

    func testLeavingTheBottomLetsTheTopDrop() {
        XCTAssertEqual(P.leave("b", from: ["b", "a"]), ["a"])
        XCTAssertEqual(P.leave("x", from: ["b", "a"]), ["b", "a"])
    }

    func testSlotHeights() {
        XCTAssertEqual(P.lift(slot: 0, boxHeight: 63), 0, "the bottom slot is flush with the edge, as before")
        XCTAssertEqual(P.lift(slot: 1, boxHeight: 63), 63 + P.gap)
    }
}
