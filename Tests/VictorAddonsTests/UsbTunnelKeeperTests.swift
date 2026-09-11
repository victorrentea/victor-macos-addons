import XCTest
@testable import VictorAddons

/// The parsing half of the tunnel's "verify, don't assume" rule.
///
/// The bug these guard against: `UsbTunnelKeeper` used to short-circuit its poll
/// on an in-process `armed` flag, so a reverse rule dropped without an unplug
/// edge (an `adb kill-server`, a deploy script, adbd restarting) stayed dead for
/// the rest of the session. The tablet then fell to the internet relay and every
/// tap silently did nothing. The poll now reads `adb reverse --list` instead —
/// which makes how that listing is read worth pinning down.
final class UsbTunnelKeeperTests: XCTestCase {
    func testRecognisesTheArmedRule() {
        XCTAssertTrue(UsbTunnelKeeper.ruleListMentionsPort("UsbFfs tcp:55123 tcp:55123\n", port: 55123))
    }

    func testEmptyListingIsNotArmed() {
        XCTAssertFalse(UsbTunnelKeeper.ruleListMentionsPort("", port: 55123))
        XCTAssertFalse(UsbTunnelKeeper.ruleListMentionsPort("\n", port: 55123))
    }

    func testOtherPortsDoNotCount() {
        let listing = "UsbFfs tcp:8081 tcp:8081\nUsbFfs tcp:5037 tcp:5037\n"
        XCTAssertFalse(UsbTunnelKeeper.ruleListMentionsPort(listing, port: 55123))
    }

    /// The rule is matched on **both** sides, so a tunnel that merely forwards
    /// some other local port to ours is not mistaken for the one we arm.
    func testForwardingToOurPortFromAnotherPortIsNotOurRule() {
        XCTAssertFalse(UsbTunnelKeeper.ruleListMentionsPort("UsbFfs tcp:9999 tcp:55123\n", port: 55123))
    }

    /// A port whose decimal form is a prefix of ours must not match: `tcp:5512`
    /// appears inside `tcp:55123` as a substring, and a naive `contains` on the
    /// bare port would have said yes.
    func testPrefixPortDoesNotMatch() {
        XCTAssertFalse(UsbTunnelKeeper.ruleListMentionsPort("UsbFfs tcp:5512 tcp:5512\n", port: 55123))
    }

    func testFindsTheRuleAmongOthers() {
        let listing = "UsbFfs tcp:8081 tcp:8081\nUsbFfs tcp:55123 tcp:55123\nUsbFfs tcp:5037 tcp:5037\n"
        XCTAssertTrue(UsbTunnelKeeper.ruleListMentionsPort(listing, port: 55123))
    }
}
