import XCTest
@testable import VictorAddons

final class VirtualDesktopCornerPolicyTests: XCTestCase {

    func testPointerParkedFourSecondsSendsTheFaceLeft() {
        var p = VirtualDesktopCornerPolicy()
        XCTAssertEqual(p.update(inHome: true, now: 0), .right)
        XCTAssertEqual(p.update(inHome: true, now: 3.9), .right)
        XCTAssertEqual(p.update(inHome: true, now: 4.0), .left)
    }

    func testLeavingBeforeFourSecondsRestartsTheCount() {
        var p = VirtualDesktopCornerPolicy()
        _ = p.update(inHome: true, now: 0)
        _ = p.update(inHome: false, now: 3)
        XCTAssertEqual(p.update(inHome: true, now: 3.5), .right)
        XCTAssertEqual(p.update(inHome: true, now: 7.4), .right)
        XCTAssertEqual(p.update(inHome: true, now: 7.5), .left)
    }

    func testFaceComesHomeThreeSecondsAfterThePointerLeavesTheCorner() {
        var p = VirtualDesktopCornerPolicy()
        _ = p.update(inHome: true, now: 0)
        _ = p.update(inHome: true, now: 4)
        XCTAssertEqual(p.update(inHome: true, now: 10), .left, "still working in the corner")
        XCTAssertEqual(p.update(inHome: false, now: 11), .left)
        XCTAssertEqual(p.update(inHome: false, now: 13.9), .left)
        XCTAssertEqual(p.update(inHome: false, now: 14), .right)
    }

    func testComingBackToTheCornerCancelsTheReturn() {
        var p = VirtualDesktopCornerPolicy()
        _ = p.update(inHome: true, now: 0)
        _ = p.update(inHome: true, now: 4)
        _ = p.update(inHome: false, now: 5)
        _ = p.update(inHome: true, now: 7)
        XCTAssertEqual(p.update(inHome: false, now: 8), .left)
        XCTAssertEqual(p.update(inHome: false, now: 10.9), .left)
        XCTAssertEqual(p.update(inHome: false, now: 11), .right)
    }
}
