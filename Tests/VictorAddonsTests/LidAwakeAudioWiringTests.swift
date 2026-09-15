import XCTest

/// The three lines of `LidAwake` that the heartbeat's audibility hangs on, and
/// that nothing else can catch.
///
/// **Why a test that reads the source.** The mute lift is CoreAudio and IOKit
/// all the way down — there is no seam to unit-test it through — and the one
/// mistake it invites is silent in every place you would look for it: dropping
/// the `liftMute()` call while keeping the method. Swift warns about neither,
/// a debug build keeps the dead method (so `strings` still finds its log lines
/// and the binary looks right), and the **release** build quietly optimises it
/// away. That is exactly how it shipped once, on 2026-09-15: the app was
/// installed, the Mac was muted, `/test/lid-awake/state` said
/// `muted:true, mute_lifted:false` tick after tick, and the only proof anything
/// was wrong was a missing string in the release binary.
///
/// The ordering assertion is the same shape: `hold(false)` is what calls
/// `pmset sleepnow`, so the audio has to be put back *above* that line. Move
/// the restore below it and everything still compiles, still passes, and the
/// Mac wakes up at full volume in the next meeting.
final class LidAwakeAudioWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        // Tests/VictorAddonsTests/<this file> → the package root is two up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VictorAddons/\(name)"),
                          encoding: .utf8)
    }

    func testBeatsLiftTheMuteAndPutItBack() throws {
        let src = try source("LidAwake.swift")
        XCTAssertTrue(src.contains("\n            liftMute()\n"),
                      "boostForBeats(true) must call liftMute() — a muted Mac parked at 100% is 100% of silence")
        XCTAssertTrue(src.contains("\n            restoreMute()\n"),
                      "boostForBeats(false) must call restoreMute() — the Mac has to wake up as quiet as it went in")
    }

    func testTheAudioIsRestoredBeforeTheMacIsAllowedToSleep() throws {
        let src = try source("LidAwake.swift")
        guard let restore = src.range(of: "boostForBeats(false)\n            Self.sleepNow()") else {
            return XCTFail("hold() must restore the volume and the mute immediately before Self.sleepNow() — "
                + "a restore on the line after the sleep is a line that may never run")
        }
        XCTAssertFalse(restore.isEmpty)
    }
}
