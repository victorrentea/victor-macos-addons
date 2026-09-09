import XCTest
@testable import VictorAddons

final class LidAwakePolicyTests: XCTestCase {

    // MARK: - The Claude gate is the point of the feature

    func testBeatsWithAClaudeWorking_LidShut_OnBattery() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false, battery: 80),
            .beat)
    }

    func testReleasesWhenNoClaudeIsWorking() {
        // The whole reason the gate exists: with dozens of sessions open all
        // day, "a claude exists" would mean the Mac never sleeps again.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false, battery: 80),
            .release)
    }

    func testReleaseIsSoft_TheRowStaysArmed() {
        // .release and .standDown are different outcomes precisely so the
        // caller can keep watching after one and disarm after the other.
        XCTAssertNotEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false, battery: 80),
            .standDown)
    }

    // MARK: - When to make a sound

    func testOpenLidHoldsButStaysSilent() {
        // Still holding the flag — a session is working — but a pulse every
        // 10 s at the desk would make the feature unusable.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: false, onAC: false, battery: 80),
            .hold)
    }

    func testOnACHoldsButStaysSilentEvenWithTheLidShut() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: true, battery: 80),
            .hold)
    }

    func testDisabledReleases() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: false, claudeWorking: true, lidClosed: true, onAC: false, battery: 5),
            .release)
    }

    // MARK: - The five last beats

    func testAudiblePulseEndingGetsTheFiveLastBeats() {
        // The case Victor asked for: lid shut, on battery, the pulse has been
        // running, and the last Claude just finished. The Mac is about to
        // sleep and the bag is told so.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, beating: true),
            .farewell)
    }

    func testFarewellIsStillARelease_TheRowStaysArmed() {
        // .farewell is .release with a sound in front of it, not a stand-down:
        // the next session to start work must re-arm without a click.
        XCTAssertNotEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, beating: true),
            .standDown)
    }

    func testNoFarewellIfThePulseWasNotRunning() {
        // Nothing was beating, so there is no ear mid-conversation to sign off
        // to — this is the release that happens all day at the desk.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, beating: false),
            .release)
    }

    func testNoFarewellWithTheLidOpen() {
        // Lid up between the beat and the finish: Victor is at the desk, and
        // five beats at the desk are noise, not a proof.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: false, onAC: false,
                                  battery: 80, beating: true),
            .release)
    }

    func testNoFarewellOnAC() {
        // Plugged in, so the lid close was macOS's own clamshell case and the
        // pulse was never announcing anything.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: true,
                                  battery: 80, beating: true),
            .release)
    }

    func testDisarmingNeverPlaysTheFarewell() {
        // A deliberate click is not the sleep this sound is about.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: false, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, beating: true),
            .release)
    }

    func testTheFloorBeatsTheFarewell() {
        // Below 20% the three Bassos are the signature, and they say something
        // different: this was the floor, not the work finishing.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 9, beating: true),
            .standDown)
    }

    func testAWorkingClaudeStillBeats_NoFarewell() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 80, beating: true),
            .beat)
    }

    // MARK: - The floor

    func testStandsDownBelowTheFloor() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false, battery: 19),
            .standDown)
    }

    func testExactlyAtTheFloorStillRuns() {
        // "sub 20%" — 20 is not below 20.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false, battery: 20),
            .beat)
    }

    func testFloorIsCheckedBeforeTheHeartbeat() {
        // The tick that stands down must not also sound like a healthy pulse.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false, battery: 3),
            .standDown)
    }

    func testFloorBeatsTheClaudeGate() {
        // At 3% with nothing working, the answer is the hard stop, not the soft
        // release — otherwise the row would stay armed at 3% and re-arm the
        // moment any session woke up.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false, battery: 3),
            .standDown)
    }

    func testFloorDoesNotApplyOnAC() {
        // Plugged in at 4%: the number is going up, and cutting the flag here
        // would sleep the Mac for no reason.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: true, battery: 4),
            .hold)
    }

    func testUnreadableBatteryDoesNotStandDown() {
        // A failed read is not evidence of a low charge; taking the machine
        // down mid-flight on a missing number is the worse mistake.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false, battery: nil),
            .beat)
    }

    // MARK: - "Is a Claude working?"

    /// The versioned install, which is what this Mac actually runs: the binary
    /// is `.../share/claude/versions/2.1.265`, so the *version* is the file
    /// name and the process table calls the session `2.1.265`. Matching on the
    /// name found nothing while six sessions were working; the path is what
    /// holds.
    private let claudePath = "/Users/victorrentea/.local/share/claude/versions/2.1.265"

    private func paths(_ map: [Int32: String]) -> (Int32) -> String? { { map[$0] } }

    func testCaffeinateWithAClaudeParentCounts() {
        XCTAssertTrue(ClaudeActivity.isClaudeWorking(
            in: [
                RunningProcess(pid: 3316, ppid: 1, name: "2.1.265"),
                RunningProcess(pid: 87607, ppid: 3316, name: "caffeinate"),
            ],
            executablePath: paths([3316: claudePath])))
    }

    func testIdleSessionsWithNoCaffeinateDoNotCount() {
        // Sessions sitting at a prompt. This is the case that must NOT hold the
        // lid open, or Victor's two dozen open terminals never let the Mac
        // sleep again.
        XCTAssertFalse(ClaudeActivity.isClaudeWorking(
            in: [
                RunningProcess(pid: 3316, ppid: 1, name: "2.1.265"),
                RunningProcess(pid: 5937, ppid: 1, name: "2.1.265"),
                RunningProcess(pid: 11512, ppid: 1, name: "2.1.263"),
            ],
            executablePath: paths([3316: claudePath, 5937: claudePath, 11512: claudePath])))
    }

    func testAHandStartedCaffeinateDoesNotCount() {
        // `caffeinate` typed into a shell holds the Mac awake on its own terms;
        // it is not a Claude session and must not arm this feature.
        XCTAssertFalse(ClaudeActivity.isClaudeWorking(
            in: [
                RunningProcess(pid: 400, ppid: 1, name: "zsh"),
                RunningProcess(pid: 401, ppid: 400, name: "caffeinate"),
            ],
            executablePath: paths([400: "/bin/zsh"])))
    }

    func testOneWorkingSessionAmongManyIdleOnesIsEnough() {
        XCTAssertTrue(ClaudeActivity.isClaudeWorking(
            in: [
                RunningProcess(pid: 3316, ppid: 1, name: "2.1.265"),
                RunningProcess(pid: 5937, ppid: 1, name: "2.1.265"),
                RunningProcess(pid: 12660, ppid: 1, name: "2.1.263"),
                RunningProcess(pid: 53787, ppid: 12660, name: "caffeinate"),
            ],
            executablePath: paths([3316: claudePath, 5937: claudePath, 12660: claudePath])))
    }

    func testAVanishedParentIsNotWorking() {
        // The parent exited between reading the table and resolving its path.
        XCTAssertFalse(ClaudeActivity.isClaudeWorking(
            in: [RunningProcess(pid: 401, ppid: 400, name: "caffeinate")],
            executablePath: paths([:])))
    }

    func testEmptyTableIsNotWorking() {
        XCTAssertFalse(ClaudeActivity.isClaudeWorking(in: [], executablePath: paths([:])))
    }

    // MARK: - Which binaries count as Claude Code

    func testVersionedInstallCounts() {
        XCTAssertTrue(ClaudeActivity.isClaudeExecutable(path: claudePath))
    }

    func testPlainInstallCounts() {
        XCTAssertTrue(ClaudeActivity.isClaudeExecutable(path: "/opt/homebrew/bin/claude"))
    }

    func testClaudeShapedWrappersDoNotCount() {
        // These live in ~/.local/bin next to the real one and wrap other models
        // or other machines. None of them should hold this laptop's lid open,
        // which is why the test is not a substring search for "claude".
        XCTAssertFalse(ClaudeActivity.isClaudeExecutable(path: "/Users/victorrentea/workspace/codex-gpt/codex-gpt"))
        XCTAssertFalse(ClaudeActivity.isClaudeExecutable(path: "/Users/victorrentea/workspace/claude-local/claude-local"))
        XCTAssertFalse(ClaudeActivity.isClaudeExecutable(path: "/Users/victorrentea/workspace/claude-docker/claude-docker"))
    }

    // MARK: - Reading the flag back out of `pmset -g`

    /// Verbatim from `pmset -g` on this Mac. The columns are **tab**-separated,
    /// which is the whole point of this test: the first version split on `" "`
    /// alone, so the read-back never saw the `1`, the toggle reported failure,
    /// and the row sat unticked over a live SleepDisabled flag.
    private let pmsetOutput = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
     hibernatemode        3
     displaysleep         15
    """

    func testFlagIsReadThroughTabColumns() {
        XCTAssertTrue(LidAwake.parseSleepDisabled(fromPmsetOutput: pmsetOutput))
    }

    func testClearedFlagReadsFalse() {
        // Once set, the line stays in the output and reads 0 — a missing line
        // is not the only way to be off.
        XCTAssertFalse(LidAwake.parseSleepDisabled(
            fromPmsetOutput: pmsetOutput.replacingOccurrences(of: "SleepDisabled\t\t1",
                                                              with: "SleepDisabled\t\t0")))
    }

    func testAbsentLineIsOff() {
        // Never set since boot: pmset does not print the line at all.
        XCTAssertFalse(LidAwake.parseSleepDisabled(fromPmsetOutput: """
        System-wide power settings:
        Currently in use:
         standby              1
        """))
    }

    func testSpaceSeparatedColumnsAlsoParse() {
        // Not what this Mac emits today, but the neighbouring rows in the very
        // same output are space-padded — the parser must not care which it got.
        XCTAssertTrue(LidAwake.parseSleepDisabled(fromPmsetOutput: " SleepDisabled        1"))
    }
}
