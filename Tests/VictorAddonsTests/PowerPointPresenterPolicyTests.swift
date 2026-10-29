import XCTest
@testable import VictorAddons

/// Where Presenter View and the slides go. The home desk of 2026-10-22 is the
/// case that started it: PowerPoint sent Presenter View to the right DELL because
/// that one had the lowest Quartz id that day.
final class PowerPointPresenterPolicyTests: XCTestCase {

    private let retina = PresenterScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isBuiltin: true)
    private let rightDell = PresenterScreen(id: 3, frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), isBuiltin: false)
    private let leftDell = PresenterScreen(id: 4, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isBuiltin: false)
    private let topDell = PresenterScreen(id: 5, frame: CGRect(x: -89, y: -1080, width: 1920, height: 1080), isBuiltin: false)

    func testHomeDeskPresenterGoesToLeftDellWhateverTheIds() {
        let screens = [retina, rightDell, leftDell, topDell]
        XCTAssertEqual(PowerPointPresenterPolicy.presenterTarget(screens), leftDell.frame)
        XCTAssertEqual(PowerPointPresenterPolicy.slidesTarget(screens), retina.frame)
    }

    func testAsusOnTheRightIsStillTheOnlyExternal() {
        let asus = PresenterScreen(id: 2, frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), isBuiltin: false)
        XCTAssertEqual(PowerPointPresenterPolicy.presenterTarget([retina, asus]), asus.frame)
    }

    /// 2026-10-29 at a venue: PowerPoint took the room TV (4) out of the Retina's
    /// mirror when the show started; it goes back, the ASUS (5) was never in it.
    func testRoomTvBrokenOutOfTheMirrorGoesBack() {
        XCTAssertEqual(PowerPointPresenterPolicy.toRemirror(mirroredBefore: [4], online: [1, 4, 5],
                                                            mirroringRetina: []), [4])
    }

    func testNothingToRemirrorWhenStillMirroredOrUnplugged() {
        XCTAssertEqual(PowerPointPresenterPolicy.toRemirror(mirroredBefore: [4], online: [1, 4, 5],
                                                            mirroringRetina: [4]), [])
        XCTAssertEqual(PowerPointPresenterPolicy.toRemirror(mirroredBefore: [4], online: [1, 5],
                                                            mirroringRetina: []), [])
    }

    func testLaptopAloneMovesNothing() {
        XCTAssertNil(PowerPointPresenterPolicy.presenterTarget([retina]))
        XCTAssertNil(PowerPointPresenterPolicy.slidesTarget([retina]))
    }

    func testWindowCountsAsOnTheScreenHoldingItsCentre() {
        XCTAssertTrue(PowerPointPresenterPolicy.isOn(leftDell.frame, window: CGRect(x: -1920, y: 0, width: 1920, height: 1080)))
        XCTAssertFalse(PowerPointPresenterPolicy.isOn(leftDell.frame, window: rightDell.frame))
    }
}
