import AppKit
import XCTest
@testable import VictorAddons

/// The 🎤 dead-transmitter alarm's state rules, headless: no screens means no
/// panels, which leaves exactly the logic — sticky, first time wins, click clears.
final class MicDeadAlarmTests: XCTestCase {

    private func alarm() -> MicDeadAlarm { MicDeadAlarm(screensProvider: { [] }, sound: {}) }

    func testRaisingRemembersWhenTheSilenceBegan() {
        let a = alarm()
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        a.raise(since: since)
        XCTAssertTrue(a.isRaised)
        XCTAssertEqual(a.silentSince, since)
    }

    func testAudioComingBackDoesNotTakeItDown() {
        let a = alarm()
        a.raise(since: Date())
        a.audioResumed()
        XCTAssertTrue(a.isRaised, "sticky: only Victor's click clears it")
    }

    func testASecondReportKeepsTheFirstTime() {
        let a = alarm()
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        a.raise(since: first)
        a.raise(since: first.addingTimeInterval(300))
        XCTAssertEqual(a.silentSince, first)
    }

    func testClickClearsAndTheNextDeathRaisesAgain() {
        let a = alarm()
        a.raise(since: Date(timeIntervalSince1970: 1_790_000_000))
        a.acknowledge(by: "click")
        XCTAssertFalse(a.isRaised)
        let second = Date(timeIntervalSince1970: 1_790_003_600)
        a.raise(since: second)
        XCTAssertEqual(a.silentSince, second)
    }

    func testTextNamesTheTransmitterAndTheTime() {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 26; c.hour = 15; c.minute = 10
        let since = Calendar.current.date(from: c)!
        XCTAssertEqual(MicDeadAlarm.text(since: since),
                       "🎤 DJI transmitter is silent — battery dead? (since 15:10)")
    }

    func testTestHooksRoute() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/mic-dead"), .testMicDead(nil))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/mic-dead?screens=all"), .testMicDead("all"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/mic-dead/state"), .testMicDeadState)
    }
}
