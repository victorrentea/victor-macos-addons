import XCTest
@testable import VictorAddons

/// The blackout that follows every break-timer close comes down on the first
/// input AFTER it appeared — never on the click that closed the timer.
final class ScreenBlackoutPolicyTests: XCTestCase {

    private func shouldDismiss(now: CFTimeInterval, startedAt: CFTimeInterval, idle: CFTimeInterval) -> Bool {
        ScreenBlackout.Policy.shouldDismiss(now: now, startedAt: startedAt, idleSeconds: idle)
    }

    /// The ✕ click landed 0.05s before the covers went up: it must NOT dismiss
    /// its own blackout (otherwise closing by hand would black the screen for
    /// exactly one frame).
    func testClickThatClosedTheTimerDoesNotDismiss() {
        // now = 100, blackout started at 99.9, last input at 99.85 (before it)
        XCTAssertFalse(shouldDismiss(now: 100, startedAt: 99.9, idle: 0.15))
    }

    /// Victor comes back and jiggles the mouse → the last input is after the
    /// covers appeared → down they go.
    func testInputAfterBlackoutDismisses() {
        // now = 300, started at 100, last input 0.2s ago (i.e. at 299.8)
        XCTAssertTrue(shouldDismiss(now: 300, startedAt: 100, idle: 0.2))
    }

    /// Nobody touched the Mac since the break ended → stay black.
    func testStillIdleKeepsItBlack() {
        // last input at 99 (1s before the blackout), 200s of idling since
        XCTAssertFalse(shouldDismiss(now: 300, startedAt: 100, idle: 201))
    }

    /// Long absence, then a keystroke: dismissed the moment the input is newer
    /// than the blackout, however old the blackout is.
    func testDismissesAfterALongAbsence() {
        XCTAssertTrue(shouldDismiss(now: 3600, startedAt: 100, idle: 1))
    }

    // MARK: - Expiry gate: an occupied Mac never gets blacked out

    private func shouldBlackout(idle: CFTimeInterval) -> Bool {
        ScreenBlackout.Policy.shouldBlackoutOnExpiry(idleSecondsAtExpiry: idle)
    }

    /// Victor is back and typing when the countdown runs out → no covers at all.
    func testWorkingAtTheMacOnExpirySkipsTheBlackout() {
        XCTAssertFalse(shouldBlackout(idle: 0))
        XCTAssertFalse(shouldBlackout(idle: 3))
        XCTAssertFalse(shouldBlackout(idle: 9.9))
    }

    /// The room is still empty → black, as before.
    func testIdleOnExpiryStillBlacksOut() {
        XCTAssertTrue(shouldBlackout(idle: 11))
        XCTAssertTrue(shouldBlackout(idle: 600))
    }

    /// Exactly at the window edge counts as "he's here" (the gate is
    /// `> atTheMacWindow`), so a 10s-old nudge still suppresses the covers.
    func testExactlyAtTheWindowEdgeCountsAsPresent() {
        XCTAssertFalse(shouldBlackout(idle: ScreenBlackout.Policy.atTheMacWindow))
    }
}
