import XCTest
@testable import VictorAddons

/// The whole point of `TranscriptActivity` is telling *speech* apart from
/// whisper's own bookkeeping. Getting that wrong is not cosmetic: the device
/// markers used to refresh the transcript's mtime, which silently granted
/// another staleness window every time whisper switched microphone — that is how
/// a dead capture thread went unnoticed for a full day.
final class TranscriptActivityTests: XCTestCase {

    func testSpeechLineIsRecognised() {
        let stamp = TranscriptActivity.speechStamp(in: "[14:03] Victor: hello there")
        XCTAssertEqual(stamp?.hour, 14)
        XCTAssertEqual(stamp?.minute, 3)
    }

    func testAudienceLineIsSpeechToo() {
        XCTAssertNotNil(TranscriptActivity.speechStamp(in: "[09:59] Audience:  a question"))
    }

    func testDeviceMarkerIsNotSpeech() {
        XCTAssertNil(TranscriptActivity.speechStamp(in: "--- Victor → 💻 ---"))
    }

    func testEmptyLineAfterStampIsNotSpeech() {
        XCTAssertNil(TranscriptActivity.speechStamp(in: "[14:03]   "))
    }

    func testMalformedStampsAreRejected() {
        XCTAssertNil(TranscriptActivity.speechStamp(in: "14:03 Victor: hi"))
        XCTAssertNil(TranscriptActivity.speechStamp(in: "[99:99] Victor: hi"))
        XCTAssertNil(TranscriptActivity.speechStamp(in: "[1:03] Victor: hi"))
        XCTAssertNil(TranscriptActivity.speechStamp(in: ""))
    }

    func testLastSpeechIgnoresTrailingMarkers() {
        let tail = """
        [10:00] Victor: good morning
        [10:05] Victor: let's begin
        --- Victor → 💻 ---
        --- Victor → 🎤 ---
        """
        let hm = TranscriptActivity.lastSpeechMinutes(inTail: tail)
        XCTAssertEqual(hm?.hour, 10)
        XCTAssertEqual(hm?.minute, 5)
    }

    /// The exact shape of today's broken file: markers only, not one word.
    func testMarkersOnlyMeansNoSpeechAtAll() {
        let tail = """
        --- Victor → 💻 ---
        --- Victor → 💻 ---
        """
        XCTAssertNil(TranscriptActivity.lastSpeechMinutes(inTail: tail))
    }
}

/// The 📬 menu item's title.
final class FluxInboxMenuTests: XCTestCase {

    func testNeverCheckedAndNothingLaunched() {
        XCTAssertEqual(FluxInboxMenu.title(lastCheck: nil, launches: 0),
                       "📬 Check Inbox")
    }

    func testShowsAgeAndRocketCount() {
        let now = Date()
        XCTAssertEqual(
            FluxInboxMenu.title(lastCheck: now.addingTimeInterval(-60), now: now, launches: 2),
            "📬 Check Inbox (1m ago, 2🚀)")
    }

    func testOmitsZeroRockets() {
        let now = Date()
        XCTAssertEqual(
            FluxInboxMenu.title(lastCheck: now.addingTimeInterval(-300), now: now, launches: 0),
            "📬 Check Inbox (5m ago)")
    }

    func testRocketsWithoutACheckYet() {
        XCTAssertEqual(FluxInboxMenu.title(lastCheck: nil, launches: 3),
                       "📬 Check Inbox (3🚀)")
    }

    func testAgeBuckets() {
        XCTAssertEqual(FluxInboxMenu.ago(0), "now")
        XCTAssertEqual(FluxInboxMenu.ago(59), "now")
        XCTAssertEqual(FluxInboxMenu.ago(60), "1m ago")
        XCTAssertEqual(FluxInboxMenu.ago(59 * 60), "59m ago")
        XCTAssertEqual(FluxInboxMenu.ago(3600), "1h ago")
        XCTAssertEqual(FluxInboxMenu.ago(25 * 3600), "1d ago")
    }
}
