import XCTest
@testable import VictorAddons

/// 🛰️ Claude RC in background — the once-a-minute decision, without a tmux
/// server or a Claude login.
final class ClaudeRemoteControlPolicyTests: XCTestCase {

    /// The whole point of the tick: Remote Control died (login expired, the
    /// server was killed, the Mac came back from a bad sleep) and nothing but
    /// this notices. It is also what "after the app restarts I expect it back"
    /// resolves to, because `startIfEnabled` runs exactly this decision once at
    /// launch instead of waiting a minute.
    func testArmedAndDeadStartsIt() {
        XCTAssertEqual(ClaudeRemoteControlPolicy.decide(enabled: true, sessionAlive: false), .start)
    }

    /// The tmux session double-forks away from whoever spawned it, so it
    /// normally outlives the rebuild loop. A tick that "restarted" it anyway
    /// would drop every session the phone has open.
    func testArmedAndAliveIsLeftAlone() {
        XCTAssertEqual(ClaudeRemoteControlPolicy.decide(enabled: true, sessionAlive: true), .leaveAlone)
    }

    /// Only reached through the toggle's own edge — see the next test for why
    /// the *tick* must never land here.
    func testDisarmedAndAliveKillsIt() {
        XCTAssertEqual(ClaudeRemoteControlPolicy.decide(enabled: false, sessionAlive: true), .kill)
    }

    /// The asymmetry that makes the unticked row liveable. `decide` is called
    /// only while the timer runs, and the timer is cancelled on unticking — but
    /// if that ever changed, a disarmed tick finding a session it did not start
    /// (Victor ran `claude-rc.sh` by hand, or attached a tmux of his own) must
    /// not shoot it once a minute. Off means "the app is not minding this", not
    /// "the app forbids it".
    func testDisarmedAndDeadDoesNothing() {
        XCTAssertEqual(ClaudeRemoteControlPolicy.decide(enabled: false, sessionAlive: false), .leaveAlone)
    }

    /// The bug this default exists to prevent: `UserDefaults.bool(forKey:)`
    /// answers `false` for a key nobody has written, which on a fresh Mac — or
    /// after a `defaults delete` — would ship the feature off and silently take
    /// the phone's ability to open sessions with it. The LaunchAgent this
    /// replaces was unconditional; the untouched state has to match it.
    func testDefaultIsOnWhenNobodyHasEverTouchedIt() {
        let key = ClaudeRemoteControlSettings.enabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(ClaudeRemoteControlSettings.isEnabled)

        ClaudeRemoteControlSettings.isEnabled = false
        XCTAssertFalse(ClaudeRemoteControlSettings.isEnabled)
    }

    /// The poll interval Victor asked for in words ("poll la 1 min"), pinned so
    /// a later tidy-up cannot quietly stretch it.
    func testPollsEveryMinute() {
        XCTAssertEqual(ClaudeRemoteControl.pollInterval, 60)
        XCTAssertEqual(ClaudeRemoteControl.sessionName, "claude-rc")
    }
}
