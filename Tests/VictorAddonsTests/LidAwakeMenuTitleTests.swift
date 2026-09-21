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

    func testTheInactiveModesHaveNothingInFront() {
        for mode in LidAwakeMode.allCases where mode != .interactive {
            let title = Menu.title(mode, current: .interactive)
            XCTAssertEqual(title, Menu.label(mode))
            XCTAssertFalse(title.hasPrefix("✅"), "\(mode) is not the current mode and must carry no tick")
        }
    }

    func testTheCurrentModeIsTheSameWordsBehindATick() {
        for mode in LidAwakeMode.allCases {
            let on = Menu.title(mode, current: mode)
            XCTAssertTrue(on.hasPrefix("✅ "))
            XCTAssertTrue(on.hasSuffix(Menu.label(mode)),
                          "the words must not change with the state — only what is in front of them")
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
