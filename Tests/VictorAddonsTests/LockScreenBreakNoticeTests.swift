import XCTest
@testable import VictorAddons

final class LockScreenBreakNoticeTests: XCTestCase {
    func testCardIsCentredAndInsideTheScreen() {
        let screen = NSRect(x: 1512, y: -200, width: 2560, height: 1440)
        let f = LockScreenBreakNotice.cardFrame(in: screen)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 1)
        XCTAssertTrue(screen.contains(f))
        XCTAssertLessThanOrEqual(f.width, 820)          // capped on big monitors
    }

    func testRetinaCardScalesWithTheScreen() {
        let f = LockScreenBreakNotice.cardFrame(in: NSRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(f.width, 605, accuracy: 1)
    }

    func testSubtitleSaysWhenToBeBack() {
        let c = LockScreenBreakNotice.Content(digits: "06:12", finish: "16:29", flag: "🇷🇴", paused: false)
        XCTAssertEqual(LockScreenBreakNotice.subtitle(c), "back at 🇷🇴 16:29")
        var noFlag = c; noFlag.flag = ""
        XCTAssertEqual(LockScreenBreakNotice.subtitle(noFlag), "back at 16:29")
        var held = c; held.paused = true
        XCTAssertEqual(LockScreenBreakNotice.subtitle(held), "⏸ paused")
    }
}
