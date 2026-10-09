import XCTest
@testable import VictorAddons

final class VirtualDesktopPlacementTests: XCTestCase {
    private let retinaLeft = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    private let asusMain = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testItGoesPastTheAsusWhenTheAsusIsOnTheRight() {
        let virtual = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        XCTAssertEqual(VirtualDesktopPlacement.origin(virtual: virtual, physical: [retinaLeft, asusMain]),
                       CGPoint(x: 1920, y: 0))
    }

    func testItGoesPastTheRetinaWhenTheAsusIsOnTheLeft() {
        let retina = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let asus = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let virtual = CGRect(x: 1512, y: 500, width: 1920, height: 1080)
        XCTAssertEqual(VirtualDesktopPlacement.origin(virtual: virtual, physical: [retina, asus]),
                       CGPoint(x: 1512, y: 0))
    }

    func testAlreadyLastMeansNoMove() {
        let virtual = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertNil(VirtualDesktopPlacement.origin(virtual: virtual, physical: [retinaLeft, asusMain]))
    }
}
