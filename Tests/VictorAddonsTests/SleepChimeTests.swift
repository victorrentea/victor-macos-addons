import XCTest
@testable import VictorAddons

/// The 😴 sleep chime: the table of when it may raise the volume, plus the two
/// lines of wiring its whole point hangs on.
final class SleepChimeTests: XCTestCase {

    // MARK: - When the chime may take the output up

    func testTheBagGetsTheBoost() {
        // Lid shut, silence: nobody can see the screen, so the sound is the
        // only report — on the charger as much as in the bag (2026-09-23).
        XCTAssertEqual(
            SleepChimePolicy.boost(lidClosed: true, otherAppPlaying: nil),
            .boost)
    }

    func testAnOpenLidChimesAtWhateverLevelVictorChose() {
        // He is looking at the screen; the screen already told him.
        XCTAssertEqual(
            SleepChimePolicy.boost(lidClosed: false, otherAppPlaying: nil),
            .asIs)
    }

    func testMusicVetoesTheBoostRatherThanTheChime() {
        // The same refusal `LidAwake.boostForBeats` makes: unmuting a Mac with
        // an open stream puts the playlist in the room. The door still sounds —
        // it just doesn't get to move the slider.
        XCTAssertEqual(
            SleepChimePolicy.boost(lidClosed: true, otherAppPlaying: "com.spotify.client"),
            .refuse("com.spotify.client"))
    }

    func testAnEmptyNameIsNobodyPlaying() {
        // `SystemAudioActivity` answers "" for none as well as nil.
        XCTAssertEqual(
            SleepChimePolicy.boost(lidClosed: true, otherAppPlaying: ""),
            .boost)
    }

    func testMusicAtTheDeskIsStillJustAsIs() {
        // .refuse and .asIs do the same thing to the volume; they differ only
        // in the log line, so the desk case must not claim a refusal it isn't.
        XCTAssertEqual(
            SleepChimePolicy.boost(lidClosed: false, otherAppPlaying: "com.spotify.client"),
            .asIs)
    }

    // MARK: - The file has to be there, and it has to be short

    func testTheToneIsOnDisk() {
        XCTAssertNotNil(AddonSounds.shared.soundURL(for: SleepChime.file),
                        "\(SleepChime.file) must resolve — a chime whose file was renamed is the silence "
                        + "this feature exists to abolish")
    }

    func testClosingTheLidNeverBecomesAWait() {
        // The handler blocks the machine's sleep for this long. Swapping the
        // file for a 30 s one must not make closing the lid a thing you wait
        // through.
        XCTAssertLessThanOrEqual(SleepChime.maxBlock, 3.5)
        if let duration = AddonSounds.shared.soundDuration(SleepChime.file) {
            XCTAssertLessThan(duration - SleepChime.toneStart, 2.5, "the tone is longer than the chime budget")
        }
    }

    // MARK: - Wiring nothing else can catch

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VictorAddons/\(name)"),
                          encoding: .utf8)
    }

    func testWillSleepDoesNotTryToPlay() throws {
        // Measured 2026-09-23 on every sleep since the chime shipped: once
        // willSleep is delivered, coreaudiod no longer starts new output. The
        // call looked like a feature and was a 17 s sleep delay with the
        // speakers unmuted at 100% and no sound. Putting it back needs the Mac
        // held awake first (SleepDisabled), not this notification.
        let src = try source("AppDelegate.swift")
        guard let start = src.range(of: "@objc private func handleWillSleep()"),
              let end = src.range(of: "@objc private func handleDidWake()") else {
            return XCTFail("handleWillSleep / handleDidWake not found")
        }
        let body = src[start.upperBound..<end.lowerBound]
        XCTAssertFalse(body.replacingOccurrences(of: "//.*", with: "", options: .regularExpression)
                           .contains("SleepChime.sound()"),
                       "willSleep cannot make a sound — the audio device is already refusing to start")
    }

    func testTheLidCloseHoldsTheSleepForTheToneThenLetsGo() throws {
        // 2026-10-02: the tone moved to the lid-close edge. The order is the
        // whole feature — flag up, tone, flag down, sleep — and a tone played
        // after the flag drops is a tone racing the sleep it announces.
        let src = try source("LidAwake.swift")
        guard let start = src.range(of: "private func announceSleep()") else {
            return XCTFail("LidAwake.announceSleep not found")
        }
        let body = String(src[start.upperBound...])
        let steps = ["setSleepDisabled(true)", "SleepChime.sound()", "setSleepDisabled(false)", "sleepNow()"]
        var cursor = body.startIndex
        for step in steps {
            guard let r = body.range(of: step, range: cursor..<body.endIndex) else {
                return XCTFail("announceSleep must call \(step) after \(steps.prefix(while: { $0 != step }).joined(separator: ", "))")
            }
            cursor = r.upperBound
        }
    }

    func testOnlyABatteryLidCloseSoundsTheSleepTone() throws {
        // Victor, 2026-10-02: the sleep tone is for the bag. On AC a lid that
        // sleeps the Mac stays silent.
        let src = try source("LidAwake.swift")
        XCTAssertTrue(src.contains("if !PowerMonitor.isOnAC() { announceSleep() }"),
                      "the sleep tone must be gated on battery in announceLidClose")
    }

    func testTheChimeBlocksRatherThanSchedulingItself() throws {
        let src = try source("SleepChime.swift")
        XCTAssertTrue(src.contains("Thread.sleep(forTimeInterval:"),
                      "the handler must park the main thread until the file has played — a chime dispatched "
                      + "asynchronously is a chime scheduled onto a Mac that is already asleep")
        XCTAssertFalse(src.contains("DispatchQueue.main.async"),
                       "SleepChime must not hop queues; willSleep does not wait for a later runloop turn")
    }

    func testTheAudioIsPutBackBeforeAnythingCanGoWrong() throws {
        // Same trap as `LidAwake`'s: a restore that runs after the playback
        // line is a restore that a throw, a cap or a freezing machine skips —
        // and the Mac wakes up unmuted at 100% in the next meeting.
        let src = try source("SleepChime.swift")
        guard let restore = src.range(of: "defer {"),
              let play = src.range(of: "player.play(atTime:") else {
            return XCTFail("SleepChime must both register a defer and start a player")
        }
        XCTAssertLessThan(restore.lowerBound, play.lowerBound,
                          "the volume/mute restore must be deferred *before* playback starts, so every exit "
                          + "path from here leaves the output as it was found")
    }
}
