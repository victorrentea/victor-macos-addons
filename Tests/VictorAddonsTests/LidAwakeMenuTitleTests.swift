import XCTest
@testable import VictorAddons

/// The 🔋 row's title carries its own tick, because the native one (`NSMenuItem
/// .state`) makes AppKit reserve a check column for the **whole** menu and
/// shifts every other row's text sideways — and this menu is read by the emoji
/// at the start of each row.
///
/// Worth a test for one reason: the bug it guards is invisible in code review
/// and obvious on screen. A stray marker on the off title, or a missing one on
/// the on title, is a switch that lies about whether the Mac sleeps in a bag.
final class LidAwakeMenuTitleTests: XCTestCase {

    func testOffHasNothingInFront() {
        XCTAssertEqual(MenuBarManager.LidAwakeMenu.title(false), "Claude prevents sleep")
        XCTAssertEqual(MenuBarManager.LidAwakeMenu.title(false).first, "C",
                       "the off row must start with the word itself — no emoji, no tick, nothing")
    }

    func testOnIsTheSameWordsBehindATick() {
        let on = MenuBarManager.LidAwakeMenu.title(true)
        XCTAssertTrue(on.hasPrefix("✅ "))
        XCTAssertTrue(on.hasSuffix(MenuBarManager.LidAwakeMenu.title(false)),
                      "the words must not change with the state — only what is in front of them")
    }

    /// The label names the subject: it is *Claude* that prevents the sleep, not
    /// the switch. "Keep Awake" would promise the thing this deliberately does
    /// not do — hold the Mac up when nothing is working.
    func testTheLabelNamesClaudeRatherThanPromisingToKeepTheMacAwake() {
        let off = MenuBarManager.LidAwakeMenu.title(false)
        XCTAssertTrue(off.contains("Claude"))
        XCTAssertFalse(off.lowercased().contains("keep awake"))
    }
}
