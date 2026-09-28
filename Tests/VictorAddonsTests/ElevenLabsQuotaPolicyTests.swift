import XCTest
@testable import VictorAddons

final class ElevenLabsQuotaPolicyTests: XCTestCase {
    private typealias P = ElevenLabsQuotaPolicy
    private let utc = TimeZone(identifier: "UTC")!

    func testEnvValueToleratesQuotesCommentsAndExport() {
        let text = """
        # a comment
        ELEVENLABS_API_KEY="sk_abc"
        export WT_ELEVEN_QUOTA='30 000'
        WT_OTHER=1
        """
        XCTAssertEqual(P.envValue("ELEVENLABS_API_KEY", in: text), "sk_abc")
        XCTAssertEqual(P.quota(fromEnv: text), 30_000)
        XCTAssertNil(P.quota(fromEnv: "WT_ELEVEN_MODEL=scribe_v2"))
    }

    func testMissingUserReadIsRecognised() {
        let body = Data(#"{"detail":{"status":"missing_permissions","message":"missing user_read"}}"#.utf8)
        XCTAssertEqual(P.parseSubscription(status: 401, body: body), .missingUserRead)
    }

    func testSubscriptionGivesAllThreeNumbers() {
        let body = Data(#"{"character_count":1234,"character_limit":10000,"next_character_count_reset_unix":1790812800}"#.utf8)
        XCTAssertEqual(P.parseSubscription(status: 200, body: body),
                       .ok(used: 1234, limit: 10000, reset: Date(timeIntervalSince1970: 1790812800)))
    }

    func testCharacterStatsAreSummed() {
        let body = Data(#"{"time":[1,2,3],"usage":{"All":[2874.0,0.0,35.0]}}"#.utf8)
        XCTAssertEqual(P.sumCharacterStats(body), 2909)
    }

    func testTitleGroupsThousandsAndSaysWhenTheResetIsUnknown() {
        let s = P.Snapshot(used: 8766, total: 10000, reset: nil, usedSource: "", totalSource: "",
                           subscriptionStatus: 401, missingUserRead: true)
        XCTAssertEqual(P.title(s, error: nil, timeZone: utc), "🧾 ElevenLabs: 1 234 / 10 000 left · resets ?")
        XCTAssertFalse(s.exhausted)
        XCTAssertTrue(P.tooltip(s, error: nil, fetchedAt: nil).contains("user_read"))
    }

    func testOverdrawnShowsNegativeAndIsExhausted() {
        let s = P.Snapshot(used: 10033, total: 10000, reset: Date(timeIntervalSince1970: 1790812800),
                           usedSource: "", totalSource: "", subscriptionStatus: 200, missingUserRead: false)
        XCTAssertEqual(P.title(s, error: nil, timeZone: utc), "🧾 ElevenLabs: −33 / 10 000 left · resets 1 Oct")
        XCTAssertTrue(s.exhausted)
    }
}
