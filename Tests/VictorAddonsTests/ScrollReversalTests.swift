import CoreGraphics
import XCTest
@testable import VictorAddons

/// The one thing worth pinning down here is that **every** delta field flips,
/// not just the line delta an old app reads — the classic bug is a terminal that
/// obeys while a smooth-scrolling browser carries on the original way.
final class ScrollReversalTests: XCTestCase {

    private func wheelEvent(lines y: Int32, _ x: Int32) -> CGEvent {
        // .line units → a discrete wheel, i.e. isContinuous == 0.
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
    }

    func testDiscreteWheelIsReversed() {
        XCTAssertTrue(ScrollReversal.shouldReverse(isContinuous: 0))
    }

    func testContinuousTrackpadIsLeftAlone() {
        XCTAssertFalse(ScrollReversal.shouldReverse(isContinuous: 1))
    }

    func testEveryDeltaFieldFlips() {
        let e = wheelEvent(lines: 3, -2)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventIsContinuous), 0)

        let beforeLineY = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let beforeLineX = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let beforePointY = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let beforePointX = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let beforeFixedY = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let beforeFixedX = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)

        XCTAssertTrue(ScrollReversal.apply(to: e))

        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventDeltaAxis1), -beforeLineY)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventDeltaAxis2), -beforeLineX)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -beforePointY)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -beforePointX)
        XCTAssertEqual(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -beforeFixedY, accuracy: 0.0001)
        XCTAssertEqual(e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), -beforeFixedX, accuracy: 0.0001)

        // The fixture has to actually carry something on all six, or the
        // assertions above pass on a heap of zeroes and prove nothing.
        XCTAssertNotEqual(beforeLineY, 0)
        XCTAssertNotEqual(beforeLineX, 0)
        XCTAssertNotEqual(beforePointY, 0)
        XCTAssertNotEqual(beforePointX, 0)
        XCTAssertNotEqual(beforeFixedY, 0)
        XCTAssertNotEqual(beforeFixedX, 0)
    }

    func testApplyingTwiceIsTheIdentity() {
        let e = wheelEvent(lines: 5, 0)
        let original = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        ScrollReversal.apply(to: e)
        ScrollReversal.apply(to: e)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventDeltaAxis1), original)
    }
}

/// LinearMouse's two rules, and the silence it kept about everything else.
final class BackButtonEnterTests: XCTestCase {

    func testBarePressIsAPlainReturn() {
        XCTAssertEqual(BackButtonEnter.returnFlags(for: []), [])
    }

    func testCommandPressIsCommandReturn() {
        XCTAssertEqual(BackButtonEnter.returnFlags(for: .maskCommand), .maskCommand)
    }

    func testEventNoiseIsNotAModifier() {
        // Real mouse events carry maskNonCoalesced; it is not something pressed.
        XCTAssertEqual(BackButtonEnter.returnFlags(for: [.maskNonCoalesced]), [])
        XCTAssertEqual(BackButtonEnter.returnFlags(for: [.maskCommand, .maskNonCoalesced]), .maskCommand)
    }

    func testEveryOtherModifierPassesThrough() {
        for flags: CGEventFlags in [.maskControl, .maskAlternate, .maskShift,
                                    [.maskCommand, .maskShift], [.maskCommand, .maskControl],
                                    [.maskCommand, .maskAlternate]] {
            XCTAssertNil(BackButtonEnter.returnFlags(for: flags), "\(flags.rawValue) should fall through")
        }
    }

    func testButtonNumberIsTheRearThumbButton() {
        XCTAssertEqual(BackButtonEnter.buttonNumber, 3)
    }
}
