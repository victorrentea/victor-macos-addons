import AppKit
import XCTest
@testable import VictorAddons

final class PhoneLowBatteryAlarmTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var defaults: UserDefaults!
    private var alarm: PhoneLowBatteryAlarm!

    override func setUp() {
        _ = NSApplication.shared  // `BottomLeftBanner.show` reads `NSApp`'s appearance.
        defaults = UserDefaults(suiteName: "PhoneLowBatteryAlarmTests")
        defaults.removePersistentDomain(forName: "PhoneLowBatteryAlarmTests")
        alarm = PhoneLowBatteryAlarm(screensProvider: { [] }, defaults: defaults)
    }

    private func set(_ pct: Int, charging: Bool = false) {
        alarm.update(PhoneCharge.Reading(pct: pct, charging: charging, ageS: 0, fetchedAt: now), now: now)
    }

    func testRisesOnlyUnderThirty() {
        set(30)
        XCTAssertFalse(alarm.isRaised)
        set(29)
        XCTAssertTrue(alarm.isRaised)
    }

    func testStaysUpUntilClickedAsTheChargeFalls() {
        set(29); set(12)
        XCTAssertTrue(alarm.isRaised)
    }

    func testGoesOnTheCharger() {
        set(20)
        set(20, charging: true)
        XCTAssertFalse(alarm.isRaised)
        XCTAssertFalse(alarm.isDismissed)
    }

    func testAnOldReadingTakesItDown() {
        set(20)
        alarm.update(PhoneCharge.Reading(pct: 20, charging: false, ageS: Int(PhoneBatteryPolicy.staleAfter) + 1, fetchedAt: now), now: now)
        XCTAssertFalse(alarm.isRaised)
    }

    func testDismissedStaysAwayUpToThirtyOne() {
        set(25)
        alarm.dismiss()
        set(20); set(31); set(20)
        XCTAssertFalse(alarm.isRaised)
    }

    func testAboveThirtyOneItCanComeBack() {
        set(25)
        alarm.dismiss()
        set(32); set(29)
        XCTAssertTrue(alarm.isRaised)
    }

    func testTheDismissalSurvivesARestart() {
        set(25)
        alarm.dismiss()
        alarm = PhoneLowBatteryAlarm(screensProvider: { [] }, defaults: defaults)
        set(25)
        XCTAssertFalse(alarm.isRaised)
    }
}
