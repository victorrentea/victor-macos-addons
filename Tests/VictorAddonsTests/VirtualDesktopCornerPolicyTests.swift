import XCTest
@testable import VictorAddons

final class VirtualDesktopCornerPolicyTests: XCTestCase {

    func testResting3sOnTheShadowOffersTheButtonButMovesNothing() {
        var p = VirtualDesktopCornerPolicy()
        p.update(onShadow: true, inHome: true, now: 0)
        p.update(onShadow: true, inHome: true, now: 2.9)
        XCTAssertFalse(p.offering)
        p.update(onShadow: true, inHome: true, now: 3)
        XCTAssertTrue(p.offering)
        p.update(onShadow: true, inHome: true, now: 60)
        XCTAssertEqual(p.corner, .right, "never moves on its own")
    }

    func testInsideTheRectangleButOffTheShadowOffersNothing() {
        var p = VirtualDesktopCornerPolicy()
        p.update(onShadow: false, inHome: true, now: 0)
        p.update(onShadow: false, inHome: true, now: 10)
        XCTAssertFalse(p.offering)
    }

    func testLeavingTheShadowHidesTheButtonAndRestartsTheCount() {
        var p = VirtualDesktopCornerPolicy()
        p.update(onShadow: true, inHome: true, now: 0)
        p.update(onShadow: true, inHome: true, now: 3)
        p.update(onShadow: false, inHome: true, now: 4)
        XCTAssertFalse(p.offering)
        p.update(onShadow: true, inHome: true, now: 5)
        p.update(onShadow: true, inHome: true, now: 7.9)
        XCTAssertFalse(p.offering)
        p.update(onShadow: true, inHome: true, now: 8)
        XCTAssertTrue(p.offering)
    }

    func testClickMovesLeftAndItComesHome3sAfterLeavingTheRectangle() {
        var p = VirtualDesktopCornerPolicy()
        p.update(onShadow: true, inHome: true, now: 0)
        p.update(onShadow: true, inHome: true, now: 3)
        p.chooseLeft()
        XCTAssertEqual(p.corner, .left)
        XCTAssertFalse(p.offering)
        p.update(onShadow: false, inHome: true, now: 10)
        XCTAssertEqual(p.corner, .left, "still working in the corner")
        p.update(onShadow: false, inHome: false, now: 11)
        p.update(onShadow: false, inHome: false, now: 13.9)
        XCTAssertEqual(p.corner, .left)
        p.update(onShadow: false, inHome: false, now: 14)
        XCTAssertEqual(p.corner, .right)
    }

    func testComingBackToTheRectangleCancelsTheReturn() {
        var p = VirtualDesktopCornerPolicy()
        p.chooseLeft()
        p.update(onShadow: false, inHome: false, now: 0)
        p.update(onShadow: false, inHome: true, now: 2)
        p.update(onShadow: false, inHome: false, now: 3)
        p.update(onShadow: false, inHome: false, now: 5.9)
        XCTAssertEqual(p.corner, .left)
        p.update(onShadow: false, inHome: false, now: 6)
        XCTAssertEqual(p.corner, .right)
    }
}

final class VirtualDesktopAutoSwitchTests: XCTestCase {
    func testZoomAndBothTeamsAreMeetingApps() {
        XCTAssertTrue(VirtualDesktopAutoSwitch.isMeetingApp("us.zoom.xos"))
        XCTAssertTrue(VirtualDesktopAutoSwitch.isMeetingApp("com.microsoft.teams2"))
        XCTAssertTrue(VirtualDesktopAutoSwitch.isMeetingApp("com.microsoft.teams"))
    }

    func testHelpersAndOthersAreNot() {
        XCTAssertFalse(VirtualDesktopAutoSwitch.isMeetingApp("us.zoom.CptHost"))
        XCTAssertFalse(VirtualDesktopAutoSwitch.isMeetingApp("com.google.Chrome"))
        XCTAssertFalse(VirtualDesktopAutoSwitch.isMeetingApp(nil))
    }
}
