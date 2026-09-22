import XCTest
@testable import VictorAddons

/// The device names are this Mac's real ones: `Victor's JBL Go 4`,
/// `DJI Mic Mini-B83BBE`, `MacBook Pro Speakers`, plus the Loopback device the
/// music-duck needs (`🔊OS Output`) because it is the one Victor picks by hand
/// and the one the router must never take away from him.
final class OutputRouterPolicyTests: XCTestCase {

    private let mac = "MacBook Pro Speakers"
    private let jbl = "Victor's JBL Go 4"
    private let bose = "Vic Bose"
    private let dji = "DJI Mic Mini-B83BBE"
    private let loopback = "🔊OS Output"

    // MARK: - The ladder

    func testConnectingTheSpeakersTakesTheOutput() {
        XCTAssertEqual(
            OutputRouterPolicy.takeoverTarget(previous: [mac], current: [mac, jbl], defaultOutput: mac),
            jbl)
    }

    func testNothingHappensWithoutAnEdge() {
        // Some other device appeared; the speakers were already there and are
        // already playing.
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac, jbl], current: [mac, jbl, loopback], defaultOutput: jbl))
    }

    func testAManualSwitchAwayIsNotUndone() {
        // Victor moves the output to the loopback while the JBL stays
        // connected: no device-list change, so no edge, so no takeover.
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac, jbl, loopback], current: [mac, jbl, loopback], defaultOutput: loopback))
    }

    func testAReconnectCountsAsAFreshConnect() {
        XCTAssertEqual(
            OutputRouterPolicy.takeoverTarget(previous: [mac, loopback],
                                              current: [mac, loopback, jbl],
                                              defaultOutput: loopback),
            jbl)
    }

    func testAlreadyTheDefaultOutputIsANoOp() {
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac], current: [mac, jbl], defaultOutput: jbl))
    }

    func testUnreadableDefaultOutputStillSwitches() {
        XCTAssertEqual(
            OutputRouterPolicy.takeoverTarget(previous: [mac], current: [mac, jbl], defaultOutput: nil),
            jbl)
    }

    func testTwoSpeakersAppearingAtOnceResolveDeterministically() {
        XCTAssertEqual(
            OutputRouterPolicy.takeoverTarget(previous: [mac],
                                              current: [mac, "JBL Go 4", "JBL Charge 5"],
                                              defaultOutput: mac),
            "JBL Charge 5")
    }

    // MARK: - The headset outranks the speakers

    func testTheHeadsetTakesTheOutputOffTheSpeakers() {
        XCTAssertEqual(
            OutputRouterPolicy.takeoverTarget(previous: [mac, jbl], current: [mac, jbl, bose],
                                              defaultOutput: jbl),
            bose)
    }

    func testTheSpeakersDoNotPullTheSoundOffHisHead() {
        // The JBL connects — or wakes — while the Bose is on: nothing moves.
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac, bose], current: [mac, bose, jbl], defaultOutput: bose))
    }

    func testTakingTheHeadsetOffGivesTheSpeakersTheSoundBack() {
        // Victor's ask: the boxes stay connected and silent under the headset,
        // and come back when it goes. macOS has already dropped the output to
        // the built-in speakers by the time this runs — which is why the rule
        // asks about the device that left, not about the default.
        XCTAssertEqual(
            OutputRouterPolicy.takeoverTarget(previous: [mac, jbl, bose], current: [mac, jbl],
                                              defaultOutput: mac),
            jbl)
    }

    func testTakingTheHeadsetOffWhenMacOSWasFasterIsANoOp() {
        // Same edge, but macOS re-routed to the JBL before we looked.
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac, jbl, bose], current: [mac, jbl], defaultOutput: jbl))
    }

    func testTakingTheHeadsetOffWithNoSpeakersLeavesItToMacOS() {
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac, bose], current: [mac], defaultOutput: mac))
    }

    func testDisconnectingTheSpeakersDoesNotFightMacOS() {
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac, jbl], current: [mac], defaultOutput: mac))
    }

    // MARK: - The blocklist: a microphone must never carry playback

    func testTheDjiIsNeverAnOutput() {
        XCTAssertTrue(OutputRouterPolicy.isBlocked(dji))
        XCTAssertTrue(OutputRouterPolicy.isBlocked("dji mic mini"))
        XCTAssertFalse(OutputRouterPolicy.isBlocked(jbl))
        XCTAssertFalse(OutputRouterPolicy.isBlocked(mac))
    }

    func testTheDjiGrabbingTheOutputIsUndoneOntoTheLadder() {
        XCTAssertEqual(
            OutputRouterPolicy.rescueTarget(devices: [mac, jbl, dji], defaultOutput: dji, fallback: mac),
            jbl)
    }

    func testTheDjiGrabbingTheOutputFallsBackToTheBuiltIn() {
        XCTAssertEqual(
            OutputRouterPolicy.rescueTarget(devices: [mac, dji], defaultOutput: dji, fallback: mac),
            mac)
    }

    func testTheDjiGrabbingTheOutputTakesAnythingThatPlays() {
        // No built-in reported and nothing on the ladder: the Loopback device
        // is still a speaker as far as anything downstream is concerned.
        XCTAssertEqual(
            OutputRouterPolicy.rescueTarget(devices: [loopback, dji], defaultOutput: dji, fallback: nil),
            loopback)
    }

    func testTheSystemOutputFollowsTheMediaOutput() {
        // Alerts were on the DJI while the film plays on the laptop: put them
        // where the film is, not on the ladder's own best idea (the JBL across
        // the room), or the rescue swaps one confusing split for another.
        XCTAssertEqual(
            OutputRouterPolicy.rescueTarget(devices: [mac, jbl, dji], defaultOutput: dji,
                                            prefer: mac, fallback: mac),
            mac)
    }

    func testTheSystemOutputWillNotFollowTheMediaOutputOntoAMicrophone() {
        // Both defaults on the DJI: there is nothing to follow, so the ladder.
        XCTAssertEqual(
            OutputRouterPolicy.rescueTarget(devices: [mac, jbl, dji], defaultOutput: dji,
                                            prefer: dji, fallback: mac),
            jbl)
    }

    func testAPreferredDeviceThatHasGoneIsIgnored() {
        XCTAssertEqual(
            OutputRouterPolicy.rescueTarget(devices: [mac, jbl, dji], defaultOutput: dji,
                                            prefer: "Some DAC that left", fallback: mac),
            jbl)
    }

    func testNothingToRescueOntoIsLeftAlone() {
        XCTAssertNil(OutputRouterPolicy.rescueTarget(devices: [dji], defaultOutput: dji, fallback: nil))
    }

    func testAnOrdinaryDefaultIsNotRescued() {
        XCTAssertNil(OutputRouterPolicy.rescueTarget(devices: [mac, jbl, dji], defaultOutput: jbl, fallback: mac))
        XCTAssertNil(OutputRouterPolicy.rescueTarget(devices: [mac, dji], defaultOutput: loopback, fallback: mac))
        XCTAssertNil(OutputRouterPolicy.rescueTarget(devices: [mac], defaultOutput: nil, fallback: mac))
    }

    func testTheDjiIsNeverATakeoverTargetEither() {
        // It connects while the built-in is playing: it is not on the ladder
        // and it is blocked, so the device-list edge changes nothing. (The
        // rescue rule is what deals with macOS pointing the default at it.)
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac], current: [mac, dji], defaultOutput: mac))
    }

    func testTheDjiConnectingUnderTheSpeakersChangesNothing() {
        XCTAssertNil(OutputRouterPolicy.takeoverTarget(
            previous: [mac, jbl], current: [mac, jbl, dji], defaultOutput: jbl))
    }

    // MARK: - Ranking

    func testRankPutsTheHeadsetAboveTheSpeakers() {
        XCTAssertEqual(OutputRouterPolicy.rank(bose), 0)
        XCTAssertEqual(OutputRouterPolicy.rank(jbl), 1)
        XCTAssertNil(OutputRouterPolicy.rank(mac))
        XCTAssertNil(OutputRouterPolicy.rank(loopback))
    }

    func testBestIgnoresBlockedDevices() {
        XCTAssertEqual(OutputRouterPolicy.best(of: [mac, dji, jbl, bose]), bose)
        XCTAssertEqual(OutputRouterPolicy.best(of: [mac, dji, jbl]), jbl)
        XCTAssertNil(OutputRouterPolicy.best(of: [mac, dji, loopback]))
    }

    func testTheNameMatchIsCaseInsensitiveAndSubstring() {
        XCTAssertNotNil(OutputRouterPolicy.rank("jbl charge 5"))
        XCTAssertNotNil(OutputRouterPolicy.rank("Victor's JBL Go 4"))
        XCTAssertNotNil(OutputRouterPolicy.rank("Vic Bose"))
        XCTAssertNil(OutputRouterPolicy.rank("MacBook Pro Speakers"))
    }
}
