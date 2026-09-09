import XCTest
@testable import VictorAddons

/// The two clocks of the 🏁 end-of-training sequence, without a microphone.
final class TrainingEndPolicyTests: XCTestCase {
    typealias Policy = TrainingEndSequence.Policy

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Listening: waiting the room out

    func testStillTalkingKeepsWaiting() {
        let action = Policy.decide(phase: .listening,
                                   now: t0 + 3,
                                   lastVoiceAt: t0)
        XCTAssertEqual(action, .wait)
    }

    /// A pause for breath is the case this exists to survive: nine seconds of
    /// quiet is a long thinking pause, not the end of a workshop.
    func testJustUnderTheSilenceStretchKeepsWaiting() {
        let action = Policy.decide(phase: .listening,
                                   now: t0 + Policy.silenceRequired - 0.01,
                                   lastVoiceAt: t0)
        XCTAssertEqual(action, .wait)
    }

    func testFullSilenceStretchOpensTheCountdown() {
        let action = Policy.decide(phase: .listening,
                                   now: t0 + Policy.silenceRequired,
                                   lastVoiceAt: t0)
        XCTAssertEqual(action, .startCountdown)
    }

    // MARK: - Counting down: the last window to speak into

    func testCountdownRunsWhileNobodySpeaks() {
        let started = t0
        let action = Policy.decide(phase: .countingDown(since: started),
                                   now: started + 4,
                                   lastVoiceAt: started - 20)
        XCTAssertEqual(action, .wait)
    }

    /// One word over the bar withdraws it — the announcement was wrong.
    func testVoiceDuringCountdownAborts() {
        let started = t0
        let action = Policy.decide(phase: .countingDown(since: started),
                                   now: started + 4,
                                   lastVoiceAt: started + 3.5)
        XCTAssertEqual(action, .abortCountdown)
    }

    /// The pulse that arrives at the very instant the countdown opens is the
    /// tail of the voice that just fell silent, not a new interruption — the
    /// countdown would otherwise be unable to start at all on a busy channel.
    func testVoiceExactlyAtCountdownStartDoesNotAbort() {
        let started = t0
        let action = Policy.decide(phase: .countingDown(since: started),
                                   now: started + 1,
                                   lastVoiceAt: started)
        XCTAssertEqual(action, .wait)
    }

    func testCountdownElapsedFinishes() {
        let started = t0
        let action = Policy.decide(phase: .countingDown(since: started),
                                   now: started + Policy.countdown,
                                   lastVoiceAt: started - 20)
        XCTAssertEqual(action, .finish)
    }

    func testJustBeforeTheEndIsStillTheEndPending() {
        let started = t0
        let action = Policy.decide(phase: .countingDown(since: started),
                                   now: started + Policy.countdown - 0.05,
                                   lastVoiceAt: started - 20)
        XCTAssertEqual(action, .wait)
    }

    /// An interruption in the last moment still wins over the deadline: the room
    /// gets the whole countdown to speak into, including its final tenth.
    func testVoiceBeatsTheDeadlineWhenBothAreDue() {
        let started = t0
        let action = Policy.decide(phase: .countingDown(since: started),
                                   now: started + Policy.countdown,
                                   lastVoiceAt: started + Policy.countdown - 0.1)
        XCTAssertEqual(action, .abortCountdown)
    }

    // MARK: - The reset is all the way back, not a pause

    /// After an abort the silence stretch is earned again from the interruption,
    /// not resumed from wherever it had got to.
    func testAfterAbortTheFullSilenceStretchIsRequiredAgain() {
        let spokeAt = t0
        XCTAssertEqual(Policy.decide(phase: .listening,
                                     now: spokeAt + Policy.silenceRequired - 1,
                                     lastVoiceAt: spokeAt),
                       .wait)
        XCTAssertEqual(Policy.decide(phase: .listening,
                                     now: spokeAt + Policy.silenceRequired,
                                     lastVoiceAt: spokeAt),
                       .startCountdown)
    }

    /// End to end on a timeline: talk, 10 s quiet, bar up, heckle at 4 s, quiet
    /// again, bar up again, and only the second one is allowed to run out.
    func testFullTimelineWithOneInterruption() {
        var lastVoice = t0
        var phase = Policy.Phase.listening

        XCTAssertEqual(Policy.decide(phase: phase, now: t0 + 10, lastVoiceAt: lastVoice),
                       .startCountdown)
        let firstBar = t0 + 10
        phase = .countingDown(since: firstBar)

        lastVoice = firstBar + 4                       // someone speaks
        XCTAssertEqual(Policy.decide(phase: phase, now: firstBar + 4, lastVoiceAt: lastVoice),
                       .abortCountdown)
        phase = .listening

        XCTAssertEqual(Policy.decide(phase: phase, now: lastVoice + 9, lastVoiceAt: lastVoice),
                       .wait)
        XCTAssertEqual(Policy.decide(phase: phase, now: lastVoice + 10, lastVoiceAt: lastVoice),
                       .startCountdown)
        let secondBar = lastVoice + 10
        phase = .countingDown(since: secondBar)

        XCTAssertEqual(Policy.decide(phase: phase, now: secondBar + 10, lastVoiceAt: lastVoice),
                       .finish)
    }
}
