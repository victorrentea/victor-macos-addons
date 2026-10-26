import XCTest
@testable import VictorAddons

final class ZoomEngineTests: XCTestCase {
    func testEngineToggles() {
        XCTAssertEqual(ZoomEngine.system.toggled, .share)
        XCTAssertEqual(ZoomEngine.share.toggled, .system)
    }
}
