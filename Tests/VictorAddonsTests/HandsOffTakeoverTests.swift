import XCTest
import AppKit
@testable import VictorAddons

/// ✋ "Victor took control" — the click on a 🔒 (or ⌃⌘⎋ twice) that stops the
/// automation holding the locks. Asked for on 2026-09-26: *"un click pe cele
/// patru lăcățele din colțuri, și să comunice agentului care ținea lacătele că
/// am preluat controlul și să întrerupă ce făcea."*
final class HandsOffTakeoverTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - State machine

    func testNoLocksNoTakeover() {
        var m = HandsOffTakeoverMachine()
        XCTAssertFalse(m.request(locksUp: false, at: t0))
        XCTAssertEqual(m.phase, .idle)
    }

    func testFirstRequestWithLocksUpTakesOver() {
        var m = HandsOffTakeoverMachine()
        XCTAssertTrue(m.request(locksUp: true, at: t0))
        XCTAssertEqual(m.phase, .takingOver(since: t0))
        XCTAssertTrue(m.isTakingOver)
    }

    /// Three clicks in a row out of urgency are one takeover: one marker, one
    /// signal — not three.
    func testRepeatedClicksDuringTheRedStateAreTheSameTakeover() {
        var m = HandsOffTakeoverMachine()
        XCTAssertTrue(m.request(locksUp: true, at: t0))
        XCTAssertFalse(m.request(locksUp: true, at: t0.addingTimeInterval(0.3)))
        XCTAssertFalse(m.request(locksUp: true, at: t0.addingTimeInterval(1.9)))
    }

    func testFinishReturnsToIdleAndAllowsTheNextTakeover() {
        var m = HandsOffTakeoverMachine()
        _ = m.request(locksUp: true, at: t0)
        m.finish()
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.request(locksUp: true, at: t0.addingTimeInterval(0.5)))
    }

    /// If `finish` never ran, the machine must not refuse forever.
    func testAStuckTakeoverExpiresAfterTheRedState() {
        var m = HandsOffTakeoverMachine()
        _ = m.request(locksUp: true, at: t0)
        XCTAssertTrue(m.request(locksUp: true, at: t0.addingTimeInterval(HandsOffTakeoverMachine.redStateDuration)))
    }

    func testAStuckTakeoverWithNoLocksGoesIdle() {
        var m = HandsOffTakeoverMachine()
        _ = m.request(locksUp: true, at: t0)
        XCTAssertFalse(m.request(locksUp: false, at: t0.addingTimeInterval(5)))
        XCTAssertEqual(m.phase, .idle)
    }

    // MARK: - ⌃⌘⎋ twice

    func testOnePressOnlyArms() {
        var d = HandsOffDoublePress()
        XCTAssertFalse(d.press(at: t0))
    }

    func testTwoPressesWithinASecondFire() {
        var d = HandsOffDoublePress()
        _ = d.press(at: t0)
        XCTAssertTrue(d.press(at: t0.addingTimeInterval(0.6)))
    }

    func testTwoPressesFurtherApartDoNotFireButTheSecondRearms() {
        var d = HandsOffDoublePress()
        _ = d.press(at: t0)
        XCTAssertFalse(d.press(at: t0.addingTimeInterval(1.5)))
        XCTAssertTrue(d.press(at: t0.addingTimeInterval(2.0)))
    }

    /// The pair resets on firing, so a third press starts a new pair.
    func testAThirdPressDoesNotFireAgain() {
        var d = HandsOffDoublePress()
        _ = d.press(at: t0)
        _ = d.press(at: t0.addingTimeInterval(0.2))
        XCTAssertFalse(d.press(at: t0.addingTimeInterval(0.4)))
    }

    // MARK: - Kill plan

    private let app: pid_t = 500, appGroup: pid_t = 500

    private func holder(_ h: pid_t, child: pid_t?) -> HandsOffHolder {
        HandsOffHolder(holderPid: h, holderStamp: nil, childPid: child, childStamp: nil)
    }

    /// The normal `hands-off run` case: the child leads its own group (`set -m`),
    /// so the whole group goes — the command and everything it spawned.
    func testChildInItsOwnGroupIsKilledAsAGroupAndTheWrapperIsNotified() {
        let plan = HandsOffKillPlan.make(holder: holder(1000, child: 1001), childPgid: 1001, holderPgid: 900,
                                         ownPid: app, ownPgid: appGroup)
        XCTAssertEqual(plan.notify, 1000)
        XCTAssertEqual(plan.terminate, [.group(1001)])
    }

    /// Without its own group the child shares the wrapper's — usually the
    /// agent's shell's. Killing that group would take the agent down with it.
    func testChildSharingTheWrappersGroupIsKilledAlone() {
        let plan = HandsOffKillPlan.make(holder: holder(1000, child: 1001), childPgid: 900, holderPgid: 900,
                                         ownPid: app, ownPgid: appGroup)
        XCTAssertEqual(plan.terminate, [.process(1001)])
    }

    func testOurOwnGroupIsNeverATarget() {
        let plan = HandsOffKillPlan.make(holder: holder(1000, child: 500), childPgid: 500, holderPgid: 900,
                                         ownPid: app, ownPgid: appGroup)
        XCTAssertEqual(plan.terminate, [])
        let plan2 = HandsOffKillPlan.make(holder: holder(1000, child: 1001), childPgid: 1001, holderPgid: 900,
                                          ownPid: app, ownPgid: 1001)
        XCTAssertEqual(plan2.terminate, [.process(1001)])
    }

    /// `hands-off start … ; … ; hands-off end` registers no process: the locks
    /// drop and the marker is written, nothing is signalled.
    func testNoHolderMeansNothingToSignal() {
        XCTAssertEqual(HandsOffKillPlan.make(holder: nil, childPgid: nil, holderPgid: nil,
                                             ownPid: app, ownPgid: appGroup), .empty)
    }

    func testAWrapperThatHasNotAttachedItsChildYetIsStillNotified() {
        let plan = HandsOffKillPlan.make(holder: holder(1000, child: nil), childPgid: nil, holderPgid: 900,
                                         ownPid: app, ownPgid: appGroup)
        XCTAssertEqual(plan.notify, 1000)
        XCTAssertEqual(plan.terminate, [])
    }

    func testPidOneAndOurselvesAreNeverSignalled() {
        let plan = HandsOffKillPlan.make(holder: holder(1, child: 1), childPgid: 1, holderPgid: 1,
                                         ownPid: app, ownPgid: appGroup)
        XCTAssertEqual(plan, .empty)
        let plan2 = HandsOffKillPlan.make(holder: holder(app, child: nil), childPgid: nil, holderPgid: appGroup,
                                          ownPid: app, ownPgid: appGroup)
        XCTAssertNil(plan2.notify)
    }

    // MARK: - Process identity

    func testOurOwnProcessHasAStableStamp() {
        let me = ProcessInfo.processInfo.processIdentifier
        let a = ProcessStamp.of(me), b = ProcessStamp.of(me)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertTrue(HandsOffKiller.isSame(pid: me, stamp: a))
    }

    /// A pid with a different start time is someone else: never signalled.
    func testARecycledPidIsNotTheSameProcess() {
        let me = ProcessInfo.processInfo.processIdentifier
        let stale = ProcessStamp(pid: me, startSec: 1, startUsec: 0)
        XCTAssertFalse(HandsOffKiller.isSame(pid: me, stamp: stale))
    }

    func testADeadPidIsNotTheSameProcess() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run(); p.waitUntilExit()
        XCTAssertFalse(HandsOffKiller.isSame(pid: p.processIdentifier, stamp: nil))
    }

    // MARK: - Marker

    func testMarkerCarriesWhatTheWrapperReads() throws {
        let json = HandsOffTakeoverMarker.json(at: t0, source: .click, label: "✋ claude — click pe \"Restart\"",
                                               agent: "claude", holder: holder(1000, child: 1001))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["holderPid"] as? Int, 1000)
        XCTAssertEqual(obj["childPid"] as? Int, 1001)
        XCTAssertEqual(obj["source"] as? String, "click")
        XCTAssertEqual(obj["why"] as? String, "✋ claude — click pe \"Restart\"")
        XCTAssertEqual(obj["at"] as? Int, 1_790_000_000)
        let local = HandsOffTakeoverMarker.localTime(t0)
        XCTAssertEqual(obj["atLocal"] as? String, local)
        XCTAssertEqual(obj["message"] as? String, "Victor took control at \(local) — stop what you were doing")
    }

    func testMarkerWithoutAHolderHasNoPids() throws {
        let json = HandsOffTakeoverMarker.json(at: t0, source: .keyboard, label: nil, agent: nil, holder: nil)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(obj["holderPid"])
        XCTAssertEqual(obj["source"] as? String, "keyboard")
    }

    func testLocalTimeIsHoursMinutesSeconds() {
        XCTAssertNotNil(HandsOffTakeoverMarker.localTime(t0).range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression))
    }

    // MARK: - Where the clickable locks sit

    /// On a notched screen the menu bar is 37 pt: a clickable lock 24 pt from
    /// the top would sit on the app menu and swallow an agent's click there.
    func testTopLocksClearTheMenuBar() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 945)    // 37 pt menu bar
        let box: CGFloat = 89.6
        let o = HandsOffOverlay.lockOrigins(screenFrame: frame, visibleFrame: visible, box: box, inset: 24)
        XCTAssertEqual(o.count, 4)
        for top in o[2...3] { XCTAssertLessThanOrEqual(top.y + box, visible.maxY - 8 + 0.001) }
        XCTAssertEqual(o[0], CGPoint(x: 24, y: 24))
        XCTAssertEqual(o[1].x, 1512 - box - 24, accuracy: 0.001)
    }

    func testLocksFollowASecondScreensOrigin() {
        let frame = NSRect(x: 1512, y: -200, width: 2560, height: 1440)
        let o = HandsOffOverlay.lockOrigins(screenFrame: frame, visibleFrame: frame, box: 90, inset: 24)
        XCTAssertEqual(o[0], CGPoint(x: 1536, y: -176))
        XCTAssertEqual(o[3], CGPoint(x: 1512 + 2560 - 90 - 24, y: -200 + 1440 - 90 - 24))
    }

    // MARK: - Routes

    func testTakeoverRoutesAreLocal() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/hands-off/takeover"), .testHandsOffTakeover(marker: nil))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/hands-off/takeover?marker=/tmp/m"),
                       .testHandsOffTakeover(marker: "/tmp/m"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/hands-off/takeover?marker=/tmp/m&holder=77"),
                       .testHandsOffTakeover(marker: "/tmp/m", holder: 77))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/hands-off/attach?holder=10&child=11"),
                       .handsOffAttach(holder: 10, child: 11))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/hands-off/attach?holder=10"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/hands-off/start?agent=a&what=b&ttl=5&holder=42"),
                       .handsOffStart(agent: "a", what: "b", ttl: 5, holder: 42))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/hands-off/render?appearance=dark&out=/tmp/x.png"),
                       .testHandsOffRender(dark: true, out: "/tmp/x.png"))
    }
}
