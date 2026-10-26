import XCTest
@testable import VictorAddons

/// 🖥️ The home rig: side monitors flush to the Retina, the one above centred.
final class HomeLayoutTests: XCTestCase {

    private let retina = CGSize(width: 1728, height: 1117)

    /// The layout of 2026-10-26: a 108 pt gap on the right, the top 12 pt off centre.
    func testClosesTheGapAndCentresTheTop() {
        let o = HomeLayout.origins(retina: retina, externals: [
            2: CGRect(x: -84, y: -1080, width: 1920, height: 1080),
            3: CGRect(x: 1836, y: 0, width: 1920, height: 1080),
            5: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        ])
        XCTAssertEqual(o[2], CGPoint(x: -96, y: -1080))
        XCTAssertEqual(o[3], CGPoint(x: 1728, y: 0))
        XCTAssertEqual(o[5], CGPoint(x: -1920, y: 0))
    }

    /// A side monitor dropped lower, or overlapping the Retina, still lands flush and top-aligned.
    func testSideMonitorsTopAligned() {
        let o = HomeLayout.origins(retina: retina, externals: [
            3: CGRect(x: 1500, y: 300, width: 1920, height: 1080),
            5: CGRect(x: -2100, y: -200, width: 1920, height: 1080),
        ])
        XCTAssertEqual(o[3], CGPoint(x: 1728, y: 0))
        XCTAssertEqual(o[5], CGPoint(x: -1920, y: 0))
    }

    func testTwoOnOneSideAreChainedOutwards() {
        let o = HomeLayout.origins(retina: retina, externals: [
            3: CGRect(x: 1800, y: 0, width: 1920, height: 1080),
            4: CGRect(x: 3800, y: 0, width: 1280, height: 800),
        ])
        XCTAssertEqual(o[3], CGPoint(x: 1728, y: 0))
        XCTAssertEqual(o[4], CGPoint(x: 3648, y: 0))
    }
}
