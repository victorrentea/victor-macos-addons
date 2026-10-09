import XCTest
@testable import VictorAddons

/// The 🖥️ ASUS ◀ / ▶ submenu: which display moves, and to where.
final class AsusSideTests: XCTestCase {

    private let retina = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let asusRight = CGRect(x: 1728, y: 0, width: 1920, height: 1080)

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AsusSide.key)
        super.tearDown()
    }

    /// Nothing stored must keep the arrangement this app always made.
    func testDefaultsToRight() {
        UserDefaults.standard.removeObject(forKey: AsusSide.key)
        XCTAssertEqual(AsusSide.preferred, .right)
        AsusSide.preferred = .left
        XCTAssertEqual(AsusSide.preferred, .left)
    }

    func testUnpluggingForgetsThePick() {
        AsusSide.preferred = .left
        AsusSide.forgetUnless(attached: true)
        XCTAssertEqual(AsusSide.preferred, .left)   // still plugged in: the pick holds
        AsusSide.forgetUnless(attached: false)
        XCTAssertEqual(AsusSide.preferred, .right)  // next plug-in lands on the right
    }

    func testCurrentSideFromBounds() {
        XCTAssertEqual(AsusSide.current(asus: asusRight, retina: retina), .right)
        let asusLeft = asusRight.offsetBy(dx: -1728 - 1920, dy: 0)
        XCTAssertEqual(AsusSide.current(asus: asusLeft, retina: retina), .left)
    }

    /// Retina main: the ASUS moves, its right edge flush with the Retina's left.
    func testRetinaMainMovesTheAsus() {
        XCTAssertEqual(AsusSide.move(to: .left, asus: asusRight, retina: retina, asusIsMain: false),
                       .asus(to: CGPoint(x: -1920, y: 0)))
        XCTAssertEqual(AsusSide.move(to: .right, asus: asusRight, retina: retina, asusIsMain: false),
                       .asus(to: CGPoint(x: 1728, y: 0)))
    }

    /// ASUS main (the venue scene): it keeps (0,0) and the menu bar; the
    /// Retina goes round it instead.
    func testAsusMainMovesTheRetina() {
        let asusMain = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let retinaLeft = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(AsusSide.move(to: .left, asus: asusMain, retina: retinaLeft, asusIsMain: true),
                       .retina(to: CGPoint(x: 1920, y: 0)))
        XCTAssertEqual(AsusSide.move(to: .right, asus: asusMain, retina: retinaLeft, asusIsMain: true),
                       .retina(to: CGPoint(x: -1920, y: 0)))
    }

    /// A Retina not at the origin (a monitor above it is main) is moved around,
    /// not snapped back to (0,0).
    func testFollowsTheRetinaWhereverItIs() {
        let r = CGRect(x: 200, y: 1440, width: 1728, height: 1117)
        XCTAssertEqual(AsusSide.move(to: .left, asus: asusRight, retina: r, asusIsMain: false),
                       .asus(to: CGPoint(x: 200 - 1920, y: 1440)))
    }
}
