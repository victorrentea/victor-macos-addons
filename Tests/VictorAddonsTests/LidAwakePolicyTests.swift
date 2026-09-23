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
                                  battery: 80, holding: true),
            .farewell)
    }

    func testFarewellIsStillARelease_TheRowStaysArmed() {
        // .farewell is .release with a sound in front of it, not a stand-down:
        // the next session to start work must re-arm without a click.
        XCTAssertNotEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, holding: true),
            .standDown)
    }

    func testFarewellEvenIfThePulseNeverStarted() {
        // 2026-09-23: lid shut as the last Claude finished, released before a
        // single beat, Mac slept in silence. Holding a shut lid on battery is
        // enough — this release is the one that sleeps the Mac.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, holding: true),
            .farewell)
    }

    func testNoSecondFarewellOnceTheFlagIsDown() {
        // The tick after the flatline finds nothing held: plain release, or
        // the flatline would repeat every ten seconds until the Mac sleeps.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, holding: false),
            .release)
    }

    func testNoFarewellWithTheLidOpen() {
        // Lid up between the beat and the finish: Victor is at the desk, and
        // five beats at the desk are noise, not a proof.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: false, onAC: false,
                                  battery: 80, holding: true),
            .release)
    }

    func testNoFarewellOnAC() {
        // Plugged in, so the lid close was macOS's own clamshell case and the
        // pulse was never announcing anything.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: true,
                                  battery: 80, holding: true),
            .release)
    }

    func testDisarmingNeverPlaysTheFarewell() {
        // A deliberate click is not the sleep this sound is about.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: false, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 80, holding: true),
            .release)
    }

    func testTheFloorBeatsTheFarewell() {
        // Below 20% the three Bassos are the signature, and they say something
        // different: this was the floor, not the work finishing.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: false, lidClosed: true, onAC: false,
                                  battery: 9, holding: true),
            .standDown)
    }

    func testAWorkingClaudeStillBeats_NoFarewell() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 80, holding: true),
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

    // MARK: - The internet gate (2026-09-15)
    //
    // A parked session still refreshes its `caffeinate`, so "a Claude is
    // working" stays true through an outage it can do nothing about. Only
    // activity *with* internet keeps the laptop on.

    func testABlockedClaudeStopsHoldingTheLidOpenAfterTheGrace() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 80, offlineFor: LidAwakePolicy.offlineGrace),
            .release)
    }

    func testAShortOutageChangesNothing() {
        // Wi-Fi hiccups, AP roams and a hotspot re-associating all live down
        // here; sleeping the Mac on one of them would be the feature failing.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 80, offlineFor: LidAwakePolicy.offlineGrace - 1),
            .beat)
    }

    func testTheGraceIsFiveMinutes() {
        XCTAssertEqual(LidAwakePolicy.offlineGrace, 300)
    }

    func testAnOfflineReleaseKeepsTheRowArmedSoTheNetComingBackReArmsIt() {
        // Not a `.standDown`: an outage is a reason to stop holding, never a
        // reason to stop watching. The first session to work once the link is
        // back picks this up with nobody clicking anything.
        XCTAssertNotEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 80, offlineFor: 3600),
            .standDown)
    }

    func testAnOfflineReleaseIsAnnouncedWhenThePulseWasAudible() {
        // From inside the bag "the work finished" and "the network died" mean
        // the same thing — this sleep is deliberate — so they get the same
        // flatline. The log is where the two are told apart.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 80, holding: true, offlineFor: 600),
            .farewell)
    }

    func testAnOfflineReleaseAtTheDeskIsSilent() {
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: false, onAC: false,
                                  battery: 80, holding: true, offlineFor: 600),
            .release)
    }

    func testTheBatteryFloorStillWinsOverAnOutage() {
        // Different endings, different sounds: three Bassos say "this was the
        // battery", and the floor is checked before anything else for exactly
        // that reason.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 10, offlineFor: 600),
            .standDown)
    }

    func testUnknownConnectivityIsTreatedAsOnline() {
        // `InternetWatch` reports 0 whenever it is not measuring. Sleeping a
        // Mac mid-flight because nobody was probing is the worse of the two
        // mistakes, so missing evidence never stalls the hold.
        XCTAssertEqual(
            LidAwakePolicy.decide(enabled: true, claudeWorking: true, lidClosed: true, onAC: false,
                                  battery: 80, offlineFor: 0),
            .beat)
    }
}


/// The `KERN_PROCARGS2` parse and the daemon-helper exclusion — the reason the
/// Mac would not sleep on 2026-09-10.
final class ClaudeHelperTests: XCTestCase {

    /// `[argc][exec path\0][padding][argv0\0][argv1\0]…`, built by hand so the
    /// layout is pinned here rather than by whatever this Mac happens to run.
    private func procargs2(argc: Int32, execPath: String, padding: Int, argv: [String]) -> [UInt8] {
        var buf = withUnsafeBytes(of: argc) { Array($0) }
        buf += Array(execPath.utf8) + [0]
        buf += [UInt8](repeating: 0, count: padding)
        for a in argv { buf += Array(a.utf8) + [0] }
        return buf
    }

    /// The spelling that actually runs on this Mac: `bg-spare` sits in
    /// `argv[0]` (the process title) and `argv[1]` is the flag with dashes.
    func testTheHelperIsRecognisedWithItsDashes() {
        XCTAssertEqual(ClaudeActivity.helperKind(firstArgument: "--bg-spare"), "bg-spare")
        XCTAssertEqual(ClaudeActivity.helperKind(firstArgument: "--bg-pty-host"), "bg-pty-host")
        XCTAssertEqual(ClaudeActivity.helperKind(firstArgument: "bg-spare"), "bg-spare")
        XCTAssertNil(ClaudeActivity.helperKind(firstArgument: "--session-id"))
        XCTAssertNil(ClaudeActivity.helperKind(firstArgument: "-p"))
    }

    func testReadsTheFirstArgumentPastTheExecPathPadding() {
        let buf = procargs2(argc: 3, execPath: "/Users/v/.local/share/claude/versions/2.1.267",
                            padding: 6, argv: ["claude", "bg-spare", "--bg-spare"])
        XCTAssertEqual(ClaudeActivity.parseFirstArgument(procargs2: buf), "bg-spare")
    }

    func testASessionWithNoArgumentsHasNoFirstArgument() {
        let buf = procargs2(argc: 1, execPath: "/opt/homebrew/bin/claude", padding: 3, argv: ["claude"])
        XCTAssertNil(ClaudeActivity.parseFirstArgument(procargs2: buf))
    }

    /// The trap this parse exists to avoid: a session whose *prompt* mentions
    /// the helper must stay a session, because it is the one most likely to be
    /// mid-flight when the lid comes down.
    func testAPromptMentioningTheHelperIsStillASession() {
        let buf = procargs2(argc: 3, execPath: "/opt/homebrew/bin/claude", padding: 4,
                            argv: ["claude", "-p", "fix the bg-spare bug"])
        let argv1 = ClaudeActivity.parseFirstArgument(procargs2: buf)
        XCTAssertEqual(argv1, "-p")
        XCTAssertFalse(ClaudeActivity.helperSubcommands.contains(argv1 ?? ""))
    }

    func testTheDaemonsSpareDoesNotHoldTheLidOpen() {
        let procs = [
            RunningProcess(pid: 100, ppid: 1, name: "2.1.267"),      // the spare
            RunningProcess(pid: 101, ppid: 100, name: "caffeinate"), // its caffeinate
        ]
        XCTAssertFalse(ClaudeActivity.isClaudeWorking(
            in: procs,
            executablePath: { _ in "/Users/v/.local/share/claude/versions/2.1.267" },
            helperKind: { $0 == 100 ? ClaudeActivity.helperKind(firstArgument: "--bg-spare") : nil }))
    }

    func testARealSessionStillHoldsItOpen() {
        let procs = [
            RunningProcess(pid: 200, ppid: 1, name: "2.1.267"),
            RunningProcess(pid: 201, ppid: 200, name: "caffeinate"),
        ]
        XCTAssertEqual(ClaudeActivity.workingSessions(
            in: procs,
            executablePath: { _ in "/Users/v/.local/share/claude/versions/2.1.267" },
            helperKind: { _ in nil }),
            [200])
    }

    func testTheHoldersAreReportedSortedSoTheLogIsStable() {
        let procs = [
            RunningProcess(pid: 300, ppid: 1, name: "2.1.267"),
            RunningProcess(pid: 301, ppid: 300, name: "caffeinate"),
            RunningProcess(pid: 200, ppid: 1, name: "2.1.267"),
            RunningProcess(pid: 201, ppid: 200, name: "caffeinate"),
        ]
        XCTAssertEqual(ClaudeActivity.workingSessions(
            in: procs,
            executablePath: { _ in "/opt/homebrew/bin/claude" },
            helperKind: { _ in nil }),
            [200, 300])
    }

    // MARK: - Remote-control sessions, which hold no `caffeinate` at all

    private let claudeBinary = "/Users/v/.local/share/claude/versions/2.1.274"

    /// A remote session as its presence file describes it. `status` defaults to
    /// `busy` and `statusChanged` to "just now", so a test only says the part
    /// it is about.
    private func remote(_ pid: Int32,
                        status: String = "busy",
                        statusChanged: TimeInterval = 0,
                        cwd: String = "/Users/v/workspace") -> SessionPresence {
        SessionPresence(pid: pid, sessionId: "s\(pid)", cwd: cwd, entrypoint: "sdk-cli",
                        status: status, statusUpdatedAt: Date().addingTimeInterval(-statusChanged))
    }

    /// `ages` is "how many seconds ago the transcript was last written", and
    /// `states` what its last line said. A session with no age has no
    /// transcript at all.
    private func working(_ sessions: [SessionPresence],
                         ages: [Int32: TimeInterval],
                         states: [Int32: ClaudeActivity.TranscriptState] = [:],
                         paths: [Int32: String]? = nil) -> [Int32] {
        let now = Date()
        return ClaudeActivity.remoteWorkingSessions(
            in: sessions,
            transcript: { session in
                ages[session.pid].map { (now.addingTimeInterval(-$0),
                                         states[session.pid] ?? .working) }
            },
            executablePath: { (paths ?? [:])[$0] ?? self.claudeBinary },
            now: now)
    }

    func testARemoteSessionWritingItsTranscriptIsWorking() {
        // The case the feature was blind to: a turn started from the phone,
        // thinking or running a tool, with no `caffeinate` anywhere.
        XCTAssertEqual(working([remote(5914)], ages: [5914: 30]), [5914])
    }

    func testARemoteSessionParkedAtItsPromptIsNot() {
        // Measured on the live rig: the parked remote session's transcript was
        // fourteen hours old while two working ones were under three minutes.
        XCTAssertEqual(working([remote(34155, status: "idle", statusChanged: 14 * 3600.0)],
                               ages: [34155: 14 * 3600.0]), [])
    }

    func testAFinishedTurnLetsGoAfterFifteenSeconds() {
        // What Victor asked for: shut the lid just after the remote work ended
        // and the Mac sleeps, instead of waiting out a tail.
        XCTAssertEqual(working([remote(700, status: "idle")], ages: [700: 14]), [700])
        XCTAssertEqual(working([remote(700, status: "idle")], ages: [700: 16]), [])
    }

    func testASessionWaitingForAnAnswerIsNotWorking() {
        // `waiting` is a question nobody is going to tap on a shut laptop.
        XCTAssertEqual(working([remote(703, status: "waiting")], ages: [703: 120]), [])
    }

    func testALongToolCallIsHeldWhileThereIsAnySignOfLife() {
        // Measured live: remote sessions busy for 145 and 125 minutes, with
        // transcripts 1 and 5 minutes old — genuinely inside long tool calls.
        XCTAssertEqual(working([remote(701, statusChanged: 145 * 60)], ages: [701: 60]), [701])
        // …and a session busy with nothing written at all yet is held on the
        // strength of the status change alone.
        XCTAssertEqual(working([remote(704, statusChanged: 5)], ages: [:]), [704])
    }

    func testABusySessionThatHasGoneQuietInBothIsLetGo() {
        // Blocked forever on something that never answers: no writes, no status
        // change. The cap is the only thing between that and a Mac that never
        // sleeps again.
        XCTAssertEqual(working([remote(705, statusChanged: 3600)], ages: [705: 3600]), [])
    }

    func testTheTranscriptGuardsTheFallingEdge() {
        // A status that lags, or one left behind by a restart, must not sleep
        // the Mac while lines are still being written.
        XCTAssertEqual(working([remote(706, status: "idle")], ages: [706: 2]), [706])
    }

    func testAnOlderCliWithNoStatusFallsBackToTheTranscript() {
        XCTAssertEqual(working([remote(707, status: "")], ages: [707: 14], states: [707: .finished]), [707])
        XCTAssertEqual(working([remote(707, status: "")], ages: [707: 16], states: [707: .finished]), [])
        XCTAssertEqual(working([remote(708, status: "")], ages: [708: 600], states: [708: .working]), [708])
        XCTAssertEqual(working([remote(709, status: "")], ages: [709: 301], states: [709: .unknown]), [])
    }

    // MARK: - Reading the state off the last line

    private func state(_ lines: [String]) -> ClaudeActivity.TranscriptState {
        ClaudeActivity.transcriptState(tail: lines.joined(separator: "\n"))
    }

    func testAPendingToolCallIsWork() {
        // Verbatim shape from a live remote session mid-tool-call (2.1.274).
        XCTAssertEqual(state([
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"thinking"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#,
        ]), .working)
    }

    func testAnEndedTurnIsFinishedEvenWithASystemLineAfterIt() {
        // The parked session's tail, verbatim: the `system` line lands after
        // the last assistant message and must not hide it.
        XCTAssertEqual(state([
            #"{"type":"attachment"}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text"}]}}"#,
            #"{"type":"system"}"#,
        ]), .finished)
    }

    func testAQueuedMessageIsWorkEvenAfterAnEndedTurn() {
        // A message sent from the phone while the session was finishing: the
        // queue line is the only trace of it until the turn picks it up.
        XCTAssertEqual(state([
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}"#,
            #"{"type":"queue-operation"}"#,
        ]), .working)
    }

    func testAThinkingSessionIsWork() {
        XCTAssertEqual(state([
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}"#,
            #"{"type":"user"}"#,
        ]), .working)
    }

    func testASubagentFinishingIsNotTheSessionFinishing() {
        // A sidechain `end_turn` while the parent carries on would read as
        // "everything is done" — and on a shut lid that reads as "sleep now".
        XCTAssertEqual(state([
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use"}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn"}}"#,
        ]), .working)
    }

    func testBookkeepingLinesAreNotAnAnswer() {
        XCTAssertEqual(state([#"{"type":"mode"}"#, #"{"type":"ai-title"}"#, #"{"type":"atis-latch"}"#]), .unknown)
        XCTAssertEqual(state([]), .unknown)
    }

    func testTheHalfLineTheTailWindowCutIsIgnored() {
        // The tail starts 64 KB from the end, which lands mid-line; the broken
        // first line must not stop the scan or crash it.
        XCTAssertEqual(state([
            #"ontent":[{"type":"text","text":"…"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}"#,
        ]), .finished)
    }

    func testTheTailIsReadFromTheEndOfARealFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: #"{"type":"user"}"# + "\n", count: 5000)
        try (filler + #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"# + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let tail = try XCTUnwrap(ClaudeActivity.transcriptTail(at: url, bytes: 1024))
        XCTAssertLessThanOrEqual(tail.utf8.count, 1024)
        XCTAssertEqual(ClaudeActivity.transcriptState(tail: tail), .finished)
    }

    func testAMissingTranscriptHasNoTail() {
        XCTAssertNil(ClaudeActivity.transcriptTail(at: URL(fileURLWithPath: "/nope/none.jsonl")))
    }

    func testATerminalSessionIsNotJudgedByItsTranscript() {
        // Terminal sessions already answer the sharper signal, and their
        // `caffeinate` goes away ~30 s after a turn. Giving all two dozen of
        // them a five-minute tail instead would be the regression this feature
        // exists to prevent.
        let terminal = SessionPresence(pid: 800, sessionId: "s800", cwd: "/Users/v/workspace",
                                       entrypoint: "cli", status: "busy", statusUpdatedAt: Date())
        XCTAssertEqual(working([terminal], ages: [800: 5]), [])
    }

    func testAPresenceFileLeftByADeadSessionIsNot() {
        // The file is deleted on exit, but not after a crash — and a pid can be
        // handed to something else entirely by then.
        XCTAssertEqual(working([remote(900)], ages: [900: 5], paths: [900: ""]), [])
        XCTAssertEqual(working([remote(901)], ages: [901: 5], paths: [901: "/bin/zsh"]), [])
    }

    func testARemoteSessionThatHasWrittenNothingYetIsNot() {
        // Started, never asked to do anything: `idle` and no transcript file at
        // all — measured, that is exactly what the fourth live remote session
        // looked like. (A session that says `busy` with no transcript yet is
        // the opposite case and is held; see the sign-of-life test above.)
        XCTAssertEqual(working([remote(46245, status: "idle", statusChanged: 117 * 60)], ages: [:]), [])
    }

    func testTheRemoteHoldersAreReportedSortedToo() {
        XCTAssertEqual(
            working([remote(69858), remote(5914), remote(34155, status: "idle", statusChanged: 14 * 3600.0)],
                    ages: [69858: 60.0, 5914: 10.0, 34155: 14 * 3600.0]),
            [5914, 69858])
    }

    // MARK: - Finding a remote session's transcript

    func testTheProjectSlugIsTheCwdWithEverythingElseDashed() {
        // Verbatim from this Mac, checked against all 14 live sessions.
        XCTAssertEqual(ClaudeActivity.projectSlug(cwd: "/Users/victorrentea/workspace"),
                       "-Users-victorrentea-workspace")
        XCTAssertEqual(ClaudeActivity.projectSlug(cwd: "/Users/victorrentea/workspace/petclinic-main"),
                       "-Users-victorrentea-workspace-petclinic-main")
    }

    func testDotsAndUnderscoresAreDashesToo() {
        // The rule is not "replace slashes": `victorrentea.ro` is a folder here.
        XCTAssertEqual(ClaudeActivity.projectSlug(cwd: "/Users/v/workspace/victorrentea.ro"),
                       "-Users-v-workspace-victorrentea-ro")
        XCTAssertEqual(ClaudeActivity.projectSlug(cwd: "/Users/v/my_stuff"), "-Users-v-my-stuff")
    }

    func testTheTranscriptPathIsSlugThenSessionId() {
        let path = ClaudeActivity.transcriptPath(
            for: SessionPresence(pid: 5914,
                                 sessionId: "64f5980e-c996-5796-9f83-eb92e7516b3b",
                                 cwd: "/Users/victorrentea/workspace",
                                 entrypoint: "sdk-cli",
                                 status: "busy",
                                 statusUpdatedAt: nil),
            projects: URL(fileURLWithPath: "/Users/victorrentea/.claude/projects"))
        XCTAssertEqual(path.path,
                       "/Users/victorrentea/.claude/projects/-Users-victorrentea-workspace/"
                       + "64f5980e-c996-5796-9f83-eb92e7516b3b.jsonl")
    }

    func testPresenceFilesAreReadOffDisk() throws {
        // The parse, against the shape the CLI actually writes (2.1.274).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Verbatim shape from a live remote session (2.1.274), milliseconds and
        // all — the timestamp is the field the whole decision now leans on.
        try """
        {"pid":5914,"sessionId":"64f5980e-c996-5796-9f83-eb92e7516b3b",\
        "cwd":"/Users/victorrentea/workspace","kind":"interactive",\
        "entrypoint":"sdk-cli","status":"busy","tmux":"claude-rc:@0.%0",\
        "updatedAt":1789961815975,"statusUpdatedAt":1789961815975}
        """.write(to: dir.appendingPathComponent("5914.json"), atomically: true, encoding: .utf8)
        // Not JSON, and not a presence file: neither may take the reader down.
        try "{".write(to: dir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("5914.abc.key"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeActivity.sessionPresence(dir: dir),
                       [SessionPresence(pid: 5914,
                                        sessionId: "64f5980e-c996-5796-9f83-eb92e7516b3b",
                                        cwd: "/Users/victorrentea/workspace",
                                        entrypoint: "sdk-cli",
                                        status: "busy",
                                        statusUpdatedAt: Date(timeIntervalSince1970: 1789961815.975))])
    }

    func testAMissingSessionsDirectoryIsSilent() {
        XCTAssertEqual(ClaudeActivity.sessionPresence(
            dir: URL(fileURLWithPath: "/nope/not/here")), [])
    }
}
