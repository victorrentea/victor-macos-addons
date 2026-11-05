import AppKit
import XCTest
@testable import VictorAddons

final class BannerClosePanelTests: XCTestCase {
    func testSitsInTheBannersBottomRightCorner() {
        let banner = NSRect(x: 100, y: 200, width: 1000, height: 150)

        let close = BannerClosePanel.frame(inBanner: banner)

        XCTAssertEqual(close, NSRect(x: 1064, y: 206, width: 30, height: 30))
        XCTAssertTrue(banner.contains(close))
    }
}
