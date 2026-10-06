import XCTest
@testable import VictorAddons

final class GlassSpotlightCornersTests: XCTestCase {
    private let box = CGRect(x: 100, y: 200, width: 400, height: 300)

    func testAPressNearACornerPicksThatCorner() {
        XCTAssertEqual(GlassSpotlightCorners.corner(of: box, near: CGPoint(x: 510, y: 495), reach: 60),
                       CGPoint(x: 500, y: 500))
        // Inside the box counts as much as out on the feather.
        XCTAssertEqual(GlassSpotlightCorners.corner(of: box, near: CGPoint(x: 130, y: 230), reach: 60),
                       CGPoint(x: 100, y: 200))
    }

    func testAPressAwayFromEveryCornerIsNotOurs() {
        // The middle of an edge, and the middle of the box: Walkie Talkie's.
        XCTAssertNil(GlassSpotlightCorners.corner(of: box, near: CGPoint(x: 300, y: 200), reach: 60))
        XCTAssertNil(GlassSpotlightCorners.corner(of: box, near: CGPoint(x: 300, y: 350), reach: 60))
    }

    func testTheOppositeCornerStaysPut() {
        XCTAssertEqual(GlassSpotlightCorners.opposite(CGPoint(x: 500, y: 500), in: box), CGPoint(x: 100, y: 200))
        XCTAssertEqual(GlassSpotlightCorners.opposite(CGPoint(x: 100, y: 500), in: box), CGPoint(x: 500, y: 200))
    }
}
