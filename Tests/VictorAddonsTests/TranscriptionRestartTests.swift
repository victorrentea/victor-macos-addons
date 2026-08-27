import XCTest
@testable import VictorAddons

/// `restartIfShouldBeRunning` exists because a bare stop/start had a failure
/// nobody would ever notice: on battery it *started* Whisper, and then nothing
/// stopped it again. The heartbeat returns immediately off AC, and the power
/// rule only re-applies on a transition — so a 1.8 GB model would sit there
/// draining the battery until the charger was next plugged in, with the menu
/// still reading "paused on battery".
final class TranscriptionRestartTests: XCTestCase {
    private func controller(onAC: Bool, running: Bool) -> TranscriptionController {
        TranscriptionController(
            isOnAC: { onAC },
            isWhisperRunning: { running },
            transcriptSilenceSeconds: { .infinity })
    }

    func testOnACItStopsAndThenStarts() {
        let c = controller(onAC: true, running: true)
        var events: [String] = []
        let expectation = expectation(description: "restarted")

        c.restartIfShouldBeRunning(
            stop: { events.append("stop") },
            start: { events.append("start"); expectation.fulfill() },
            delay: 0.01)

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(events, ["stop", "start"])
    }

    func testOnBatteryItNeverStarts() {
        let c = controller(onAC: false, running: true)
        var started = false
        var stopped = false

        c.restartIfShouldBeRunning(
            stop: { stopped = true }, start: { started = true }, delay: 0.01)

        // Give the delayed start every chance to fire if it were going to.
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(stopped, "a running whisper on battery should still be stopped")
        XCTAssertFalse(started, "nothing may start whisper while unplugged")
    }

    func testOnBatteryWithNothingRunningItDoesNothingAtAll() {
        let c = controller(onAC: false, running: false)
        var touched = false
        c.restartIfShouldBeRunning(
            stop: { touched = true }, start: { touched = true }, delay: 0.01)

        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(touched)
    }

    func testItArmsTheWarmUpGraceSoTheWatchdogDoesNotKillTheNewProcess() {
        // A bare stop/start skipped `noteStarted()`, leaving `runningSince`
        // unset — so in a quiet room (exactly when raw capture gets armed) the
        // output watchdog could force-restart a process that had only just
        // begun loading its model.
        let c = controller(onAC: true, running: true)
        let expectation = expectation(description: "started")
        c.restartIfShouldBeRunning(
            stop: {}, start: { expectation.fulfill() }, delay: 0.01)
        wait(for: [expectation], timeout: 2)

        // With the grace armed a moment ago, a silent transcript must NOT be
        // treated as a reason to restart again.
        XCTAssertFalse(TranscriptionController.shouldForceRestart(
            silence: .infinity, sinceStart: 1, sinceLastRestart: .infinity))
    }
}
