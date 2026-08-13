import XCTest
@testable import VictorAddons

final class CropFlashGeometryTests: XCTestCase {

    func testDragIsNormalisedWhicheverWayItWentDrawn() {
        let downRight = CropFlashGeometry.rect(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        let upLeft = CropFlashGeometry.rect(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 50))
        XCTAssertEqual(downRight, CGRect(x: 100, y: 50, width: 200, height: 200))
        XCTAssertEqual(upLeft, downRight)
    }

    /// CG counts y down from the primary's top, Cocoa counts it up from its
    /// bottom — the flip every window placement in this app has to make.
    func testFlipToCocoaCoordinates() {
        let cg = CGRect(x: 10, y: 100, width: 200, height: 50)   // 100..150 from the top
        let cocoa = CropFlashGeometry.cocoaRect(cg, primaryMaxY: 1000)
        XCTAssertEqual(cocoa, CGRect(x: 10, y: 850, width: 200, height: 50))
    }

    func testDragMatchingTheSavedPictureIsTrusted() {
        // A 400×300 pt drag on a retina screen saves 800×600 px.
        XCTAssertTrue(CropFlashGeometry.matchesCapture(
            drag: CGRect(x: 0, y: 0, width: 400, height: 300),
            imagePixels: CGSize(width: 800, height: 600), scale: 2))
        // Non-retina projector: 1:1.
        XCTAssertTrue(CropFlashGeometry.matchesCapture(
            drag: CGRect(x: 0, y: 0, width: 400, height: 300),
            imagePixels: CGSize(width: 400, height: 300), scale: 1))
    }

    /// A border in the wrong place is worse than no border, so anything that
    /// doesn't line up with the file must fail closed.
    func testMismatchIsRejected() {
        // Space-bar window pick: a click, not a drag — no rectangle to trust.
        XCTAssertFalse(CropFlashGeometry.matchesCapture(
            drag: CGRect(x: 500, y: 500, width: 0, height: 0),
            imagePixels: CGSize(width: 1200, height: 800), scale: 2))
        // A drag we started sampling half-way through.
        XCTAssertFalse(CropFlashGeometry.matchesCapture(
            drag: CGRect(x: 0, y: 0, width: 120, height: 300),
            imagePixels: CGSize(width: 800, height: 600), scale: 2))
        // Right size, wrong screen scale.
        XCTAssertFalse(CropFlashGeometry.matchesCapture(
            drag: CGRect(x: 0, y: 0, width: 400, height: 300),
            imagePixels: CGSize(width: 800, height: 600), scale: 1))
    }

    /// Sub-pixel rounding in the saved image must not cost the border.
    func testRoundingSlackIsTolerated() {
        XCTAssertTrue(CropFlashGeometry.matchesCapture(
            drag: CGRect(x: 0, y: 0, width: 400, height: 300),
            imagePixels: CGSize(width: 803, height: 597), scale: 2))
    }

    /// The border has to read on a big crop and still fit inside a tiny one.
    func testThicknessScalesWithTheCrop() {
        XCTAssertEqual(CropFlashGeometry.borderThickness(for: CGRect(x: 0, y: 0, width: 1600, height: 900)), 24)
        XCTAssertEqual(CropFlashGeometry.borderThickness(for: CGRect(x: 0, y: 0, width: 40, height: 30)), 4)
        let medium = CropFlashGeometry.borderThickness(for: CGRect(x: 0, y: 0, width: 400, height: 100))
        XCTAssertEqual(medium, 12, accuracy: 0.001)
    }
}
