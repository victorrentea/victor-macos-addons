import XCTest
@testable import VictorAddons

final class PhoneBatteryPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - Which notification counts

    func testBatteryIdentifierIsRecognised() {
        XCTAssertTrue(PhoneBatteryPolicy.isLowBatteryNotification(
            identifier: "com.soduto.services.battery.abc123",
            title: "Low Battery | Galaxy S24 Ultra"))
    }

    func testOtherSodutoNotificationsAreIgnored() {
        // Soduto posts pairing / share / SMS notifications under the same bundle
        // id; only the battery service's may blink the tablet.
        XCTAssertFalse(PhoneBatteryPolicy.isLowBatteryNotification(
            identifier: "com.soduto.services.share.abc123",
            title: "File received"))
        XCTAssertFalse(PhoneBatteryPolicy.isLowBatteryNotification(
            identifier: "com.soduto.services.telephony.abc123",
            title: "Low Battery"))   // identifier wins over a misleading title
    }

    func testTitleIsTheFallbackOnlyWhenNoIdentifier() {
        XCTAssertTrue(PhoneBatteryPolicy.isLowBatteryNotification(
            identifier: nil, title: "Low Battery | Galaxy S24 Ultra"))
        XCTAssertTrue(PhoneBatteryPolicy.isLowBatteryNotification(
            identifier: "", title: "Low Battery | Galaxy S24 Ultra"))
        XCTAssertFalse(PhoneBatteryPolicy.isLowBatteryNotification(
            identifier: nil, title: "Soduto"))
        XCTAssertFalse(PhoneBatteryPolicy.isLowBatteryNotification(identifier: nil, title: nil))
    }

    // MARK: - Reading the percentage out of the body

    func testChargeParsedFromEnglishBody() {
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: "13% of battery remaining"), 13)
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: "5% of battery remaining"), 5)
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: "100% of battery remaining"), 100)
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: "0% of battery remaining"), 0)
    }

    func testChargeParsedWhenThePercentSignFollowsWordsOrPrecedesTheSentence() {
        // The format string is localized — the number is found by its % sign,
        // wherever the translation puts the sentence around it.
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: "Baterie rămasă: 12%"), 12)
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: "Noch 8% Akku"), 8)
    }

    func testBodiesWithoutAUsablePercentage() {
        XCTAssertNil(PhoneBatteryPolicy.chargePercent(fromBody: nil))
        XCTAssertNil(PhoneBatteryPolicy.chargePercent(fromBody: ""))
        XCTAssertNil(PhoneBatteryPolicy.chargePercent(fromBody: "battery remaining"))
        XCTAssertNil(PhoneBatteryPolicy.chargePercent(fromBody: "of battery remaining 13"))
        // Out of range = not a percentage we will act on.
        XCTAssertNil(PhoneBatteryPolicy.chargePercent(fromBody: "420% of battery remaining"))
    }

    func testDigitsNotAttachedToThePercentSignAreNotMistakenForIt() {
        // "Galaxy S24" in a body must not be read as 24%.
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: "Galaxy S24 Ultra: 9% remaining"), 9)
    }

    // MARK: - Whether to warn

    func testNoReadingMeansNoWarning() {
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(nil, now: now))
    }

    func testFreshReadingWarns() {
        let r = PhoneBatteryPolicy.Reading(chargePct: 11, updatedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(PhoneBatteryPolicy.shouldWarn(r, now: now))
    }

    func testStaleReadingStopsWarning() {
        // The phone went flat and switched off: Soduto never gets the "charging"
        // packet that would clear the notification, so age is what ends it.
        let r = PhoneBatteryPolicy.Reading(chargePct: 3,
                                           updatedAt: now.addingTimeInterval(-PhoneBatteryPolicy.staleAfter - 1))
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(r, now: now))
    }

    func testReadingExactlyAtTheStalenessLimitStillWarns() {
        let r = PhoneBatteryPolicy.Reading(chargePct: 3,
                                           updatedAt: now.addingTimeInterval(-PhoneBatteryPolicy.staleAfter))
        XCTAssertTrue(PhoneBatteryPolicy.shouldWarn(r, now: now))
    }

    func testFullBatteryDoesNotWarnEvenWithAFreshNotification() {
        // The case that actually happened: Soduto kept re-delivering a battery
        // notification carrying 100%, and the tablet blinked all day at nothing.
        let r = PhoneBatteryPolicy.Reading(chargePct: 100, updatedAt: now)
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(r, now: now))
    }

    func testChargeAtTheThresholdDoesNotWarnButJustBelowItDoes() {
        let at = PhoneBatteryPolicy.Reading(chargePct: PhoneBatteryPolicy.warnBelowPct, updatedAt: now)
        XCTAssertFalse(PhoneBatteryPolicy.shouldWarn(at, now: now))
        let below = PhoneBatteryPolicy.Reading(chargePct: PhoneBatteryPolicy.warnBelowPct - 1, updatedAt: now)
        XCTAssertTrue(PhoneBatteryPolicy.shouldWarn(below, now: now))
    }

    func testFutureStampedReadingIsNotTreatedAsStale() {
        // Clock drift between the record's stamp and our poll must not silence it.
        let r = PhoneBatteryPolicy.Reading(chargePct: 7, updatedAt: now.addingTimeInterval(120))
        XCTAssertTrue(PhoneBatteryPolicy.shouldWarn(r, now: now))
    }

    // MARK: - What goes on the wire

    func testPingFieldsHideAHealthyBattery() {
        let r = PhoneBatteryPolicy.Reading(chargePct: 100, updatedAt: now)
        XCTAssertEqual(PhoneBatteryPolicy.pingFields(for: r, now: now),
                       ",\"phoneBatteryLow\":false,\"phoneBatteryPct\":-1")
    }

    func testPingFieldsWhileWarning() {
        let r = PhoneBatteryPolicy.Reading(chargePct: 14, updatedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(PhoneBatteryPolicy.pingFields(for: r, now: now),
                       ",\"phoneBatteryLow\":true,\"phoneBatteryPct\":14")
    }

    func testPingFieldsWhenClear() {
        XCTAssertEqual(PhoneBatteryPolicy.pingFields(for: nil, now: now),
                       ",\"phoneBatteryLow\":false,\"phoneBatteryPct\":-1")
    }

    func testPingFieldsHideThePercentageOnceStale() {
        let r = PhoneBatteryPolicy.Reading(chargePct: 4,
                                           updatedAt: now.addingTimeInterval(-PhoneBatteryPolicy.staleAfter - 1))
        XCTAssertEqual(PhoneBatteryPolicy.pingFields(for: r, now: now),
                       ",\"phoneBatteryLow\":false,\"phoneBatteryPct\":-1")
    }

    func testPingFieldsSpliceIntoValidJSON() {
        let r = PhoneBatteryPolicy.Reading(chargePct: 9, updatedAt: now)
        let json = "{\"ok\":true\(PhoneBatteryPolicy.pingFields(for: r, now: now))}"
        let parsed = try? XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(parsed?["phoneBatteryLow"] as? Bool, true)
        XCTAssertEqual(parsed?["phoneBatteryPct"] as? Int, 9)
    }

    // MARK: - Record decoding

    func testRequestDictionaryIsReadOutOfARecordBlob() throws {
        let record: [String: Any] = [
            "app": "com.soduto.soduto",
            "req": [
                "titl": "Low Battery | Galaxy S24 Ultra",
                "body": "13% of battery remaining",
                "iden": "com.soduto.services.battery.abc123",
            ],
        ]
        let blob = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        let req = try XCTUnwrap(PhoneBatteryMonitor.requestDictionary(from: blob))
        XCTAssertTrue(PhoneBatteryPolicy.isLowBatteryNotification(
            identifier: req["iden"] as? String, title: req["titl"] as? String))
        XCTAssertEqual(PhoneBatteryPolicy.chargePercent(fromBody: req["body"] as? String), 13)
    }

    func testGarbageBlobDecodesToNothingRatherThanThrowing() {
        XCTAssertNil(PhoneBatteryMonitor.requestDictionary(from: Data([0x00, 0x01, 0x02])))
    }
}
