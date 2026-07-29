import XCTest
import CoreGraphics
@testable import VictorAddons

/// The one rule: an unattended Terminal never opens on the built-in Retina,
/// because that display is what the venue projector mirrors.
final class TerminalWindowPlacementTests: XCTestCase {

    private func box(_ frame: CGRect, builtin: Bool) -> TerminalWindowPlacement.ScreenBox {
        TerminalWindowPlacement.ScreenBox(frame: frame, visibleFrame: frame, isBuiltin: builtin)
    }

    func testNoScreensGivesNoPlacement() {
        XCTAssertNil(TerminalWindowPlacement.bounds(screens: []))
    }

    func testBuiltInOnlyGivesNoPlacement() {
        let retina = box(CGRect(x: 0, y: 0, width: 1728, height: 1117), builtin: true)
        XCTAssertNil(TerminalWindowPlacement.bounds(screens: [retina]))
    }

    /// Retina primary, ASUS extended to its right: the window lands on the ASUS,
    /// with y flipped around the primary's top edge.
    func testExternalToTheRightOfPrimaryRetina() {
        let retina = box(CGRect(x: 0, y: 0, width: 1000, height: 800), builtin: true)
        let asus = box(CGRect(x: 1000, y: 0, width: 1000, height: 600), builtin: false)

        let b = TerminalWindowPlacement.bounds(screens: [retina, asus], areaFraction: 1.0)
        // Full-fill on the ASUS: x 1000...2000, and Cocoa y 0...600 flips to
        // Carbon top = 800 - 600 = 200, bottom = 800 - 0 = 800.
        XCTAssertEqual(b, TerminalWindowPlacement.Bounds(left: 1000, top: 200, right: 2000, bottom: 800))
    }

    /// The "projector + ASUS" rig: the ASUS is main at the origin and the Retina
    /// sits to its left at a negative x. The window must still avoid the Retina.
    func testRetinaLeftOfAsusPrimary() {
        let asus = box(CGRect(x: 0, y: 0, width: 1920, height: 1080), builtin: false)
        let retina = box(CGRect(x: -1728, y: 0, width: 1728, height: 1117), builtin: true)

        let b = TerminalWindowPlacement.bounds(screens: [asus, retina], areaFraction: 1.0)
        XCTAssertEqual(b, TerminalWindowPlacement.Bounds(left: 0, top: 0, right: 1920, bottom: 1080))
    }

    func testPicksTheLargestExternal() {
        let retina = box(CGRect(x: 0, y: 0, width: 1000, height: 800), builtin: true)
        let small = box(CGRect(x: 1000, y: 0, width: 800, height: 600), builtin: false)
        let big = box(CGRect(x: 1800, y: 0, width: 2560, height: 1440), builtin: false)

        let b = TerminalWindowPlacement.bounds(screens: [retina, small, big], areaFraction: 1.0)
        XCTAssertEqual(b?.left, 1800)
        XCTAssertEqual(b?.right, 1800 + 2560)
    }

    /// `areaFraction` is a fraction of the screen's AREA, so each side scales by
    /// its square root: a quarter of the surface is half of each side.
    func testAreaFractionCentresTheWindow() {
        let retina = box(CGRect(x: 0, y: 0, width: 1000, height: 1000), builtin: true)
        let ext = box(CGRect(x: 1000, y: 0, width: 1000, height: 1000), builtin: false)

        let b = TerminalWindowPlacement.bounds(screens: [retina, ext], areaFraction: 0.25)
        // 500x500 centred in 1000x1000 at x=1000 → x 1250...1750, y 250...750,
        // flipped around the primary top (1000) → top 250, bottom 750.
        XCTAssertEqual(b, TerminalWindowPlacement.Bounds(left: 1250, top: 250, right: 1750, bottom: 750))
    }

    /// The default is a tenth of the monitor's surface — on a 1920x1080 that is
    /// ~607x342, i.e. ~10% of the area, not 10% of each side.
    func testDefaultIsATenthOfTheSurface() {
        let retina = box(CGRect(x: 0, y: 0, width: 1728, height: 1117), builtin: true)
        let dell = box(CGRect(x: 1728, y: 0, width: 1920, height: 1080), builtin: false)

        let b = TerminalWindowPlacement.bounds(screens: [retina, dell])!
        let w = CGFloat(b.right - b.left), h = CGFloat(b.bottom - b.top)
        XCTAssertEqual(w * h / (1920 * 1080), 0.10, accuracy: 0.005)
        // Centred on the DELL.
        XCTAssertEqual(CGFloat(b.left) + w / 2, 1728 + 960, accuracy: 1)
    }

    /// A screen whose visible frame is a sliver is not worth a window.
    func testDegenerateExternalIsRejected() {
        let retina = box(CGRect(x: 0, y: 0, width: 1000, height: 800), builtin: true)
        let sliver = box(CGRect(x: 1000, y: 0, width: 60, height: 40), builtin: false)
        XCTAssertNil(TerminalWindowPlacement.bounds(screens: [retina, sliver]))
    }

    /// The primary is found by its origin, not by array position — a mirrored
    /// display filtered out of the list must not shift the flip axis.
    func testPrimaryFoundByOriginNotOrder() {
        let ext = box(CGRect(x: -1500, y: 0, width: 1500, height: 1000), builtin: false)
        let retina = box(CGRect(x: 0, y: 0, width: 1000, height: 800), builtin: true)

        let b = TerminalWindowPlacement.bounds(screens: [ext, retina], areaFraction: 1.0)
        // Flip axis is the retina's maxY (800), not the first element's.
        XCTAssertEqual(b, TerminalWindowPlacement.Bounds(left: -1500, top: -200, right: 0, bottom: 800))
    }

    func testAppleScriptSnippetFormatsBounds() {
        let retina = box(CGRect(x: 0, y: 0, width: 1000, height: 800), builtin: true)
        let ext = box(CGRect(x: 1000, y: 0, width: 1000, height: 600), builtin: false)

        let snippet = TerminalWindowPlacement.appleScriptSnippet(tabVar: "t", screens: [retina, ext])
        XCTAssertTrue(snippet.contains("set bounds of (first window whose tabs contains t) to {"))

        let none = TerminalWindowPlacement.appleScriptSnippet(tabVar: "t", screens: [retina])
        XCTAssertFalse(none.contains("set bounds"))
    }
}
