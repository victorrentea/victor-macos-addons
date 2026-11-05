import XCTest
@testable import VictorAddons

/// The power rule since 2026-11-03: **AC transcribes, battery only records**,
/// and the menu can switch the battery recording off until the next AC.
///
/// `restartIfShouldBeRunning` exists because a bare stop/start had a failure
/// nobody would ever notice: on battery it started a *full* Whisper, and nothing
/// stopped it again — a 1.8 GB model draining the battery until the charger came
/// back. It must restart in the mode the power source asks for, or not at all.
final class TranscriptionRestartTests: XCTestCase {
    private final class Fake {
        var onAC: Bool
        var running = false
        var events: [String] = []
        init(onAC: Bool) { self.onAC = onAC }
    }

    private func make(_ fake: Fake) -> TranscriptionController {
        let c = TranscriptionController(isOnAC: { fake.onAC },
                                        isWhisperRunning: { fake.running },
                                        switchDelay: 0.01)
        c.onStart = { mode in
            fake.events.append(mode == .full ? "start full" : "start capture")
            fake.running = true
        }
        c.onStop = { fake.events.append("stop"); fake.running = false }
        return c
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testTheRuleItself() {
        XCTAssertEqual(TranscriptionController.desiredMode(onAC: true, batteryRecordingEnabled: false), .full)
        XCTAssertEqual(TranscriptionController.desiredMode(onAC: false, batteryRecordingEnabled: true), .captureOnly)
        XCTAssertNil(TranscriptionController.desiredMode(onAC: false, batteryRecordingEnabled: false))
    }

    func testUnpluggingSwitchesAFullWhisperToCaptureOnly() {
        let fake = Fake(onAC: true)
        let c = make(fake)
        var states: [TranscriptionController.State] = []
        c.onStateChanged = { states.append($0) }
        c.start(); spin()
        fake.onAC = false
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events, ["start full", "stop", "start capture"])
        XCTAssertEqual(states, [.onAC, .recordingOnBattery])
    }

    func testPluggingInTranscribesAgainAndResetsTheMenuSwitch() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        c.setBatteryRecording(false); spin()
        XCTAssertEqual(fake.events, ["start capture", "stop"])
        XCTAssertFalse(fake.running)

        fake.onAC = true
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events.last, "start full")
        XCTAssertTrue(c.batteryRecordingEnabled, "the charger resets the menu's stop")

        fake.onAC = false
        c.powerDidChange(); spin()
        XCTAssertEqual(fake.events.last, "start capture", "the next unplugging records again")
    }

    func testTheMenuSwitchDoesNothingOnAC() {
        let fake = Fake(onAC: true)
        let c = make(fake)
        c.start(); spin()
        c.setBatteryRecording(false); spin()
        XCTAssertEqual(fake.events, ["start full"])
        XCTAssertTrue(c.batteryRecordingEnabled)
    }

    func testRestartOnBatteryComesBackCaptureOnly() {
        let fake = Fake(onAC: false)
        fake.running = true
        let c = make(fake)
        var started: [TranscriptionController.Mode] = []
        let done = expectation(description: "restarted")
        c.restartIfShouldBeRunning(stop: { fake.running = false },
                                   start: { started.append($0); done.fulfill() },
                                   delay: 0.01)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(started, [.captureOnly], "never a full whisper on battery")
    }

    func testRestartWithBatteryRecordingOffOnlyStops() {
        let fake = Fake(onAC: false)
        let c = make(fake)
        c.start(); spin()
        c.setBatteryRecording(false); spin()
        fake.running = true  // something started it behind our back
        var started = false
        var stopped = false
        c.restartIfShouldBeRunning(stop: { stopped = true }, start: { _ in started = true }, delay: 0.01)
        spin(0.2)
        XCTAssertTrue(stopped)
        XCTAssertFalse(started)
    }
}

final class BatteryRecordingNoticeTests: XCTestCase {
    func testShownWhileRecordingAndHiddenWhileSnoozed() {
        let now = Date()
        XCTAssertTrue(BatteryRecordingNotice.shouldShow(recording: true, snoozedUntil: nil, now: now))
        XCTAssertFalse(BatteryRecordingNotice.shouldShow(recording: false, snoozedUntil: nil, now: now))
        XCTAssertFalse(BatteryRecordingNotice.shouldShow(
            recording: true, snoozedUntil: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(BatteryRecordingNotice.shouldShow(
            recording: true, snoozedUntil: now.addingTimeInterval(-1), now: now), "the hour is over")
    }

    func testTheChargerEndsTheSnooze() {
        // Not `.recordingOnBattery`: that would draw a real panel, which a
        // test process without NSApp cannot. The snooze bookkeeping is the same.
        let n = BatteryRecordingNotice(screensProvider: { [] })
        n.update(.pausedOnBattery)
        n.snoozeNow()
        XCTAssertNotNil(n.snoozedUntil)
        n.update(.onAC)
        XCTAssertNil(n.snoozedUntil)
        XCTAssertEqual(BatteryRecordingNotice.snooze, 3600)
    }

    func testOnlyTheDotBlinksAndItBlinksForever() {
        XCTAssertEqual(BatteryRecordingNotice.text, "🔋", "the 🔴 and the waveform are pictures")
        let blink = BottomLeftBanner.blinkAnimation()
        XCTAssertEqual(blink.calculationMode, .discrete, "on battery: no 60 Hz fade")
        XCTAssertEqual(blink.duration, 2)
        XCTAssertEqual(blink.repeatCount, .infinity)
        XCTAssertFalse(blink.isRemovedOnCompletion)
    }

    func testTheWaveKeepsWalkiesProportions() {
        let wave = BatteryRecordingNotice.waveform(height: 28, colour: .white)
        XCTAssertEqual(wave.size, NSSize(width: 39, height: 28))
    }
}

final class BannerButtonOrderTests: XCTestCase {
    /// `Send` is always the upper button; the countdown still fills the auto one.
    func testSendIsAlwaysOnTop() {
        XCTAssertFalse(BottomLeftBanner.autoOnTop(click: .send), "Discard auto, Send click → Send on top")
        XCTAssertTrue(BottomLeftBanner.autoOnTop(click: .cancel), "Send auto, Cancel click → Send on top")
        XCTAssertTrue(BottomLeftBanner.autoOnTop(click: .stopUntilAC))
    }
}
