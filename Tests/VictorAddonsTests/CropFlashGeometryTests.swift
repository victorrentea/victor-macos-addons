import XCTest
@testable import VictorAddons

final class CropFlashGeometryTests: XCTestCase {

    func testRectFromEitherDragDirection() {
        let downRight = CropFlashGeometry.rect(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250))
        let upLeft = CropFlashGeometry.rect(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 50))
        XCTAssertEqual(downRight, CGRect(x: 100, y: 50, width: 200, height: 200))
        XCTAssertEqual(upLeft, downRight, "which corner you started from cannot change the box")
    }

    // MARK: - Staying on the screen

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testClampedPointStaysInsideTheScreen() {
        XCTAssertEqual(CropFlashGeometry.clamped(CGPoint(x: -40, y: 500), within: screen),
                       CGPoint(x: 0, y: 500))
        XCTAssertEqual(CropFlashGeometry.clamped(CGPoint(x: 5000, y: 4000), within: screen),
                       CGPoint(x: 1728, y: 1117))
        XCTAssertEqual(CropFlashGeometry.clamped(CGPoint(x: 400, y: 400), within: screen),
                       CGPoint(x: 400, y: 400), "a point already inside is left alone")
    }

    func testMoveFollowsTheMouseWhileThereIsRoom() {
        let box = CGRect(x: 400, y: 400, width: 200, height: 100)
        let moved = CropFlashGeometry.moved(box, by: CGVector(dx: 60, dy: -30), within: screen)
        XCTAssertEqual(moved, CGRect(x: 460, y: 370, width: 200, height: 100))
    }

    func testMoveStopsAtEveryEdgeInsteadOfLeavingTheScreen() {
        let box = CGRect(x: 20, y: 20, width: 200, height: 100)
        let left = CropFlashGeometry.moved(box, by: CGVector(dx: -500, dy: -500), within: screen)
        XCTAssertEqual(left, CGRect(x: 0, y: 0, width: 200, height: 100))

        let right = CropFlashGeometry.moved(box, by: CGVector(dx: 5000, dy: 5000), within: screen)
        XCTAssertEqual(right, CGRect(x: 1528, y: 1017, width: 200, height: 100))
        XCTAssertTrue(screen.contains(right))
    }

    func testMoveNeverResizesTheBox() {
        let box = CGRect(x: 1700, y: 1100, width: 300, height: 300)   // already overhanging
        let moved = CropFlashGeometry.moved(box, by: CGVector(dx: 900, dy: 900), within: screen)
        XCTAssertEqual(moved.size, box.size)
    }

    func testTranslationIsMeasuredFromTheTotalDeltaSoAnEdgeDoesNotStick() {
        // Push hard into the right edge, then pull back: the box must come with
        // the mouse immediately, not sit there remembering the overshoot.
        let box = CGRect(x: 1500, y: 400, width: 200, height: 100)
        let pinned = CropFlashGeometry.clampedTranslation(of: box, by: CGVector(dx: 900, dy: 0), within: screen)
        XCTAssertEqual(pinned.dx, 28, "only as far as the right edge allows")

        let back = CropFlashGeometry.clampedTranslation(of: box, by: CGVector(dx: -50, dy: 0), within: screen)
        XCTAssertEqual(back.dx, -50, "the same total delta, now legal, applies in full")
    }

    func testBoxWiderThanTheScreenPinsToTheLowEdge() {
        let huge = CGRect(x: -100, y: 0, width: 3000, height: 100)
        let moved = CropFlashGeometry.moved(huge, by: CGVector(dx: 400, dy: 0), within: screen)
        XCTAssertEqual(moved.minX, 0, "no legal position exists; do not let the clamp invert")
    }

    // MARK: - Whole points

    func testRoundingGrowsOutwardSoNothingFramedIsLost() {
        let rounded = CropFlashGeometry.rounded(CGRect(x: 10.4, y: 20.6, width: 100.3, height: 50.1))
        XCTAssertEqual(rounded, CGRect(x: 10, y: 20, width: 101, height: 51))
        XCTAssertTrue(rounded.contains(CGRect(x: 10.4, y: 20.6, width: 100.3, height: 50.1)))
    }

    // MARK: - Cocoa selection → capture pixels

    /// The retina laptop: 1728 × 1117 points photographed as 3456 × 2234 pixels.
    func testPixelCropFlipsYAndDoublesOnRetina() {
        let crop = CropFlashGeometry.pixelCrop(of: CGRect(x: 400, y: 217, width: 500, height: 300),
                                               onScreen: screen,
                                               imageWidth: 3456)
        // y: the box's top edge is 1117 - 517 = 600 points below the screen's top.
        XCTAssertEqual(crop, CGRect(x: 800, y: 1200, width: 1000, height: 600))
    }

    func testPixelCropTakesTheScaleFromThePictureNotTheScreen() {
        let nonRetina = CropFlashGeometry.pixelCrop(of: CGRect(x: 0, y: 1017, width: 200, height: 100),
                                                    onScreen: screen,
                                                    imageWidth: 1728)
        XCTAssertEqual(nonRetina, CGRect(x: 0, y: 0, width: 200, height: 100),
                       "a 1× capture crops at 1×, whatever backingScaleFactor claims")
    }

    func testPixelCropIsRelativeToTheScreensOwnOrigin() {
        // A second display parked to the right of the primary one.
        let right = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        let crop = CropFlashGeometry.pixelCrop(of: CGRect(x: 1828, y: 980, width: 100, height: 100),
                                               onScreen: right,
                                               imageWidth: 1920)
        XCTAssertEqual(crop, CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    func testBorderThicknessScalesButStaysReadable() {
        XCTAssertEqual(CropFlashGeometry.borderThickness(for: CGRect(x: 0, y: 0, width: 1600, height: 900)), 24)
        XCTAssertEqual(CropFlashGeometry.borderThickness(for: CGRect(x: 0, y: 0, width: 40, height: 30)), 4)
        let medium = CropFlashGeometry.borderThickness(for: CGRect(x: 0, y: 0, width: 400, height: 100))
        XCTAssertEqual(medium, 12, accuracy: 0.001)
    }
}
