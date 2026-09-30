import XCTest
@testable import VictorAddons

/// 🛰️ The stale-server half of the watchdog (2026-09-30): the tmux session is
/// alive, but is the `claude remote-control` inside it still able to spawn the
/// phone's sessions? Pure decision, no tmux, no `ps`, no disk.
final class ClaudeRemoteControlStalenessTests: XCTestCase {

    private func probe(server: String? = "2.1.285", exists: Bool? = true,
                       installed: String? = "2.1.285", enoent: Bool = false,
                       capacity: Int? = 0, children: Int = 0) -> ClaudeRemoteControlProbe {
        ClaudeRemoteControlProbe(serverVersion: server, serverBinaryExists: exists,
                                 installedVersion: installed, paneShowsSpawnENOENT: enoent,
                                 capacityInUse: capacity, childProcesses: children)
    }

    func testSameVersionIsHealthy() {
        XCTAssertEqual(ClaudeRemoteControlStaleness.decide(probe(), secondsSinceLastRestart: nil), .healthy)
    }

    /// Unknown is not stale: an unreadable binary must never trigger a kill.
    func testUnknownVersionsAreHealthy() {
        let p = probe(server: nil, exists: nil, installed: nil)
        XCTAssertEqual(ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: nil), .healthy)
    }

    /// 25–30 Sep 2026 exactly: server on 2.1.282, auto-update deleted it.
    func testDeletedBinaryWithNoSessionsRestarts() {
        let p = probe(server: "2.1.282", exists: false)
        guard case .restart(let why) = ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: nil)
        else { return XCTFail("expected restart") }
        XCTAssertTrue(why.contains("deleted"), why)
    }

    /// The early warning: the old binary is still on disk, but a later update
    /// will delete it, so heal while nobody is connected.
    func testVersionMismatchWithNoSessionsRestarts() {
        let p = probe(server: "2.1.284")
        XCTAssertEqual(ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: nil),
                       .restart(reason: "server on 2.1.284, installed is 2.1.285"))
    }

    func testSpawnENOENTAloneIsStale() {
        let p = probe(enoent: true)
        XCTAssertEqual(ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: nil),
                       .restart(reason: "pane shows spawn error: ENOENT"))
    }

    /// The rule that matters most: a restart kills Victor's running phone
    /// sessions. Either witness — the banner or a child process — holds it.
    func testLiveSessionsHoldTheRestart() {
        for p in [probe(server: "2.1.284", capacity: 2, children: 0),
                  probe(server: "2.1.284", capacity: nil, children: 1),
                  probe(server: "2.1.282", exists: false, enoent: true, capacity: 1, children: 1)] {
            guard case .wait = ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: nil)
            else { return XCTFail("expected wait for \(p)") }
        }
    }

    /// A server stale again right after a restart is not fixed by another one
    /// every minute.
    func testCooldownAfterARecentRestart() {
        let p = probe(enoent: true)
        guard case .wait = ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: 120)
        else { return XCTFail("expected wait inside the cooldown") }
        guard case .restart = ClaudeRemoteControlStaleness.decide(
            p, secondsSinceLastRestart: ClaudeRemoteControlStaleness.cooldown + 1)
        else { return XCTFail("expected restart after the cooldown") }
    }

    /// The reason text is the log's dedup key, so it must not change every tick.
    func testWaitReasonIsStableAcrossTicks() {
        let p = probe(enoent: true)
        XCTAssertEqual(ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: 60),
                       ClaudeRemoteControlStaleness.decide(p, secondsSinceLastRestart: 120))
    }

    // MARK: parsing

    func testVersionFromBinaryPath() {
        XCTAssertEqual(ClaudeRemoteControlStaleness.version(
            fromBinaryPath: "/Users/v/.local/share/claude/versions/2.1.285"), "2.1.285")
        XCTAssertNil(ClaudeRemoteControlStaleness.version(fromBinaryPath: "/opt/homebrew/bin/node"))
        XCTAssertNil(ClaudeRemoteControlStaleness.version(fromBinaryPath: "/x/versions/latest"))
    }

    func testCapacityFromPane() {
        let pane = """
        [21:55:29] Session failed: Process exited with error cse_018
        ·✔︎· Ready · workspace · HEAD
            Capacity: 3/32 · New sessions will be created in the current directory
        """
        XCTAssertEqual(ClaudeRemoteControlStaleness.capacityInUse(pane: pane), 3)
        XCTAssertNil(ClaudeRemoteControlStaleness.capacityInUse(pane: "Remote Control disconnected"))
    }

    func testSpawnENOENTFromPane() {
        let pane = "Session failed: spawn error: ENOENT: no such file or directory, posix_spawn '/Users/v/.local/share/claude/versions/2.1.282'"
        XCTAssertTrue(ClaudeRemoteControlStaleness.showsSpawnENOENT(pane: pane))
        XCTAssertFalse(ClaudeRemoteControlStaleness.showsSpawnENOENT(pane: "Session failed: Process exited with error"))
    }
}
