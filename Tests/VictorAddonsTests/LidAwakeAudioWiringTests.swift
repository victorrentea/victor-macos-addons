import XCTest
@testable import VictorAddons

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

    // MARK: - What counts as "something else is playing"

    func testThePermanentlyOpenPlumbingIsNotTheMusic() {
        // Each of these was, at some point, the reason the heartbeat's volume
        // boost quietly never fired: Audio Hijack and Krisp (2026-09-10),
        // Walkie Talkie (2026-09-15), Wispr Flow itself (2026-09-21).
        for id in ["com.rogueamoeba.audiohijack", "ai.krisp.krispMac",
                   "ro.victorrentea.wispr-relay", "com.electron.wispr-flow.helper"] {
            XCTAssertTrue(SystemAudioActivity.isAlwaysOpenPlumbing(bundleID: id, executablePath: String?.none),
                          "\(id) holds an output stream open at RMS 0 all day and must not veto the boost")
        }
    }

    func testTheSoundboardIsTheMusicAndStillVetoesIt() {
        // The reason Walkie Talkie is listed by its full bundle id rather than
        // as `ro.victorrentea.`: the other app in that family is the room's
        // playlist, and skipping it would take it to 100%.
        XCTAssertFalse(SystemAudioActivity.isAlwaysOpenPlumbing(
            bundleID: "ro.victorrentea.victor-effects", executablePath: String?.none))
        XCTAssertFalse(SystemAudioActivity.isAlwaysOpenPlumbing(
            bundleID: "com.apple.Music", executablePath: String?.none))
    }

    func testChromeCountsOnlyWhenItsExtensionSaysATabIsAudible() {
        // 2026-09-23: Chrome's helper held its stream open at RMS 0 and vetoed
        // the boost. It is also where the music plays, so only its own answer
        // clears it — and no answer (no extension) keeps it counted.
        let chrome = "com.google.Chrome.helper"
        XCTAssertTrue(SystemAudioActivity.isSilentChrome(bundleID: chrome, anyTabAudible: false))
        XCTAssertFalse(SystemAudioActivity.isSilentChrome(bundleID: chrome, anyTabAudible: true))
        XCTAssertFalse(SystemAudioActivity.isSilentChrome(bundleID: chrome, anyTabAudible: nil))
        XCTAssertFalse(SystemAudioActivity.isSilentChrome(bundleID: "com.apple.Music", anyTabAudible: false))
    }

    func testABundlelessProcessIsJudgedByItsBinary() {
        // Playwright's headless Chromium spawns an audio utility child with no
        // bundle id that holds a stream open at RMS 0 — measured beside Wispr
        // Flow on 2026-09-21, which is why skipping Wispr alone was not enough.
        XCTAssertTrue(SystemAudioActivity.isAlwaysOpenPlumbing(
            bundleID: "",
            executablePath: "/Users/v/Library/Caches/ms-playwright/chromium_headless_shell-1208/"
                + "chrome-headless-shell-mac-arm64/chrome-headless-shell"))
        XCTAssertFalse(SystemAudioActivity.isAlwaysOpenPlumbing(
            bundleID: "", executablePath: "/usr/bin/afplay"))
        XCTAssertFalse(SystemAudioActivity.isAlwaysOpenPlumbing(bundleID: "", executablePath: String?.none))
    }
}
