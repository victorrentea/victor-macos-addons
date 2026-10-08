import AppKit
import XCTest
@testable import VictorAddons

/// ✈️ The check-in alarm's rules, headless: which subjects name which city,
/// what the pill says, that a thread rings once, and that the queue survives a
/// restart. Subjects are the airlines' real wording; booking codes are made up.
final class CheckInMailPolicyTests: XCTestCase {

    override func setUp() { _ = NSApplication.shared }

    private func hit(_ id: String, from: String = "Ryanair", subject: String, unread: Bool = true) -> CheckInMailPolicy.Hit {
        .init(threadId: id, unread: unread, from: from, email: nil, subject: subject, date: nil)
    }

    func testDestinationFromEachAirlinesSubject() {
        let cases: [(String, String?)] = [
            ("ABC123 | Check in online for your flight to Otopeni", "Otopeni"),
            ("ABC123 | Efectuează check-in-ul online pentru zborul tău către  Palma", "Palma"),
            ("Your flight is ready for check-in | From Brussels to London on 07 October 2026", "London"),
            ("Check in for your flight to Bucharest", "Bucharest"),
            ("Check-in für Ihren Flug nach Paris am 23/04/2026", "Paris"),
            ("Check-in is open!", nil),
            ("It's time to check in!", nil),
            ("It's time to check-in. Check reservation ✈", nil),
        ]
        for (subject, city) in cases {
            XCTAssertEqual(CheckInMailPolicy.destination(subject), city, subject)
        }
    }

    func testPillText() {
        let h = hit("1", subject: "ABC123 | Check in online for your flight to Otopeni")
        XCTAssertEqual(CheckInMailPolicy.text(h), "✈️ Check in now: Ryanair → Otopeni")
        XCTAssertEqual(CheckInMailPolicy.text(h, alsoPending: 2), "✈️ Check in now: Ryanair → Otopeni  (+2)")
        let klm = hit("2", from: "KLM Royal Dutch Air.", subject: "Check-in is open!")
        XCTAssertEqual(CheckInMailPolicy.text(klm), "✈️ Check in now: KLM")
    }

    func testAThreadRingsOnce() {
        let a = hit("a", subject: "x"), b = hit("b", subject: "y")
        XCTAssertEqual(CheckInMailPolicy.fresh([a, b, a], seen: ["b"]).map(\.threadId), ["a"])
    }

    func testDueAfterAnHourOrNeverPolled() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(CheckInMailPolicy.isDue(lastCheck: nil, now: t0, every: 3600))
        XCTAssertFalse(CheckInMailPolicy.isDue(lastCheck: t0, now: t0 + 3599, every: 3600))
        XCTAssertTrue(CheckInMailPolicy.isDue(lastCheck: t0, now: t0 + 3600, every: 3600))
    }

    func testQueryCoversEveryAirlineAndOnlyRecentMail() {
        let q = CheckInMailPolicy.query
        for domain in ["ryanairemail.com", "wizznews.com", "klm", "ready for check-in",
                       "airfrance", "lot.com", "animawings"] {
            XCTAssertTrue(q.contains(domain), domain)
        }
        XCTAssertTrue(q.hasPrefix("{") && q.hasSuffix("newer_than:1d"))
        XCTAssertTrue(CheckInMailPolicy.unreadQuery.hasSuffix("is:unread"))
    }

    func testDecodesGmailCliJSON() {
        let json = """
        [{"threadId":"1a11","unread":false,"from":"Ryanair","email":null,
          "subject":"ABC123 | Check in online for your flight to Otopeni","snippet":"","date":"Thu, 8 Oct 2026, 09:35"}]
        """
        let hits = CheckInMailPolicy.decode(Data(json.utf8))
        XCTAssertEqual(hits?.first?.threadId, "1a11")
        XCTAssertNil(CheckInMailPolicy.decode(Data("not json".utf8)))
    }

    func testGmailURL() {
        XCTAssertEqual(CheckInMailPolicy.gmailURL(threadId: "1a11"), "https://mail.google.com/mail/u/0/#all/1a11")
    }

    // MARK: - The alarm's queue

    private func freshDefaults() -> UserDefaults {
        let name = "checkin-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    func testClickOpensTheMailAndMovesToTheNext() {
        let d = freshDefaults()
        var opened: [String] = []
        var rang = 0
        let alarm = CheckInAlarm(screensProvider: { [] }, sound: { rang += 1 },
                                 openURL: { opened.append($0) }, defaults: d)
        alarm.raise([hit("a", subject: "x"), hit("b", subject: "y")])
        XCTAssertEqual(rang, 1)
        alarm.raise([hit("a", subject: "x")])
        XCTAssertEqual(alarm.pending.count, 2, "the same mail again doesn't queue twice")
        XCTAssertEqual(rang, 1, "and doesn't ring again")
        alarm.acknowledge(open: true)
        XCTAssertEqual(opened, ["https://mail.google.com/mail/u/0/#all/a"])
        XCTAssertEqual(alarm.pending.map(\.threadId), ["b"])
        alarm.acknowledge(open: false)
        XCTAssertEqual(opened.count, 1, "right-click dismisses without opening")
        XCTAssertFalse(alarm.isRaised)
    }

    func testTheQueueSurvivesARestart() {
        let d = freshDefaults()
        CheckInAlarm(screensProvider: { [] }, sound: {}, openURL: { _ in }, defaults: d)
            .raise([hit("a", subject: "x")])
        let afterRestart = CheckInAlarm(screensProvider: { [] }, sound: {}, openURL: { _ in }, defaults: d)
        XCTAssertEqual(afterRestart.pending.map(\.threadId), ["a"])
        afterRestart.restore()
        afterRestart.clearAll()
        XCTAssertFalse(afterRestart.isRaised)
    }
}
