import XCTest
@testable import VictorAddons

/// The 😴 rows carry their own tick, because the native one (`NSMenuItem.state`)
/// makes AppKit reserve a check column for the **whole** menu and shifts every
/// other row's text sideways — and this menu is read by the emoji at the start
/// of each row.
///
/// Worth a test for one reason: the bug it guards is invisible in code review
/// and obvious on screen. A stray marker on an inactive row, or a missing one
/// on the active one, is a switch that lies about whether the Mac sleeps in a
/// bag.
final class LidAwakeMenuTitleTests: XCTestCase {

    typealias Menu = MenuBarManager.LidAwakeMenu

    func testTheRowsAreTheWordsAloneAndTheTickIsTheNativeOne() {
        // Victor asked for the classic Mac checkmark in this submenu
        // (2026-09-21): no marker in the text at all, the state carries it.
        // Safe here and nowhere else in this app — the check column AppKit
        // reserves belongs to these three rows, which have no leading emoji to
        // be shifted.
        for mode in LidAwakeMode.allCases {
            let label = Menu.label(mode)
            XCTAssertFalse(label.contains("✅"), "\(mode) must carry no tick of its own")
            XCTAssertTrue(label.first?.isLetter == true, "the row is the words alone")
        }
    }

    func testOnlyTheCurrentModeIsChecked() {
        for current in LidAwakeMode.allCases {
            XCTAssertEqual(Menu.state(current, current: current), .on)
            for other in LidAwakeMode.allCases where other != current {
                XCTAssertEqual(Menu.state(other, current: current), .off)
            }
        }
    }

    /// Three states hidden behind a hover would be the state you forget you
    /// left on — the exact reason this stopped being a submenu in 2026-09-17.
    /// It is a submenu again only because the parent row says which mode it is
    /// in.
    func testTheParentRowSaysWhichModeItIsIn() {
        for mode in LidAwakeMode.allCases {
            let parent = Menu.parentTitle(mode)
            XCTAssertTrue(parent.hasPrefix(Menu.name))
            XCTAssertTrue(parent.lowercased().hasSuffix(Menu.label(mode).lowercased()),
                          "the parent must name the current mode, not just the feature")
        }
        XCTAssertNotEqual(Menu.parentTitle(.off), Menu.parentTitle(.background))
    }

    /// The label names the subject: it is *Claude* that stays awake. "Keep
    /// Awake" would promise the thing this deliberately does not do — hold the
    /// Mac up when nothing is working.
    func testTheLabelNamesClaudeRatherThanPromisingToKeepTheMacAwake() {
        XCTAssertTrue(Menu.name.contains("Claude"))
        XCTAssertFalse(Menu.name.lowercased().contains("keep awake"))
    }

    // MARK: - What each mode holds the lid open for

    func testOffHoldsNothing() {
        XCTAssertFalse(LidAwakeMode.off.holdsInteractive)
        XCTAssertFalse(LidAwakeMode.off.holdsRemote)
    }

    func testInteractiveDeclinesThePhone() {
        // The whole point of the middle state: a session someone is typing at
        // holds the lid open, one driven from the phone does not.
        XCTAssertTrue(LidAwakeMode.interactive.holdsInteractive)
        XCTAssertFalse(LidAwakeMode.interactive.holdsRemote)
    }

    func testBackgroundHoldsBoth() {
        XCTAssertTrue(LidAwakeMode.background.holdsInteractive)
        XCTAssertTrue(LidAwakeMode.background.holdsRemote)
    }

    // MARK: - Nobody's lid guard changes underneath them

    func testAMacThatHadTheOldSwitchOnLandsInBackground() {
        XCTAssertEqual(LidAwakeSettings.mode(stored: nil, legacyEnabled: true), .background)
        XCTAssertEqual(LidAwakeSettings.mode(stored: nil, legacyEnabled: false), .off)
    }

    func testAWrittenModeWinsOverTheOldSwitch() {
        XCTAssertEqual(LidAwakeSettings.mode(stored: "interactive", legacyEnabled: true), .interactive)
        XCTAssertEqual(LidAwakeSettings.mode(stored: "off", legacyEnabled: true), .off)
        // A value from a future version, or a corrupted one, is not a mode.
        XCTAssertEqual(LidAwakeSettings.mode(stored: "sideways", legacyEnabled: true), .background)
    }
}
