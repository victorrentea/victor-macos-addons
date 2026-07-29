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

/// The live-but-mute restart rule.
final class TranscriptionControllerRestartTests: XCTestCase {

    private let overThreshold = TranscriptionController.silenceRestartThreshold + 1
    private let overInterval = TranscriptionController.minRestartInterval + 1

    func testRestartsWhenSilentLongEnough() {
        XCTAssertTrue(TranscriptionController.shouldForceRestart(
            silence: overThreshold, sinceStart: overThreshold, sinceLastRestart: overInterval))
    }

    func testNeverRestartsDuringWarmUp() {
        // A freshly started whisper is silent while it loads its model; that is
        // not a fault, and restarting it would guarantee it never finishes.
        XCTAssertFalse(TranscriptionController.shouldForceRestart(
            silence: .infinity, sinceStart: 30, sinceLastRestart: overInterval))
    }

    func testNeverRestartsTwiceInARow() {
        // If a restart didn't fix it, restarting every minute won't either — and
        // a loop is worse than the silence it's chasing.
        XCTAssertFalse(TranscriptionController.shouldForceRestart(
            silence: .infinity, sinceStart: overThreshold, sinceLastRestart: 60))
    }

    func testRecentSpeechIsLeftAlone() {
        XCTAssertFalse(TranscriptionController.shouldForceRestart(
            silence: 10, sinceStart: overThreshold, sinceLastRestart: overInterval))
    }

    /// Regression: `Int(.infinity)` **traps**. Silence is infinite whenever
    /// nothing has been transcribed all day — the single likeliest case when the
    /// watchdog fires — so interpolating it crashed the entire app the first two
    /// times this triggered (2026-07-29), and it crashed *before* the restart it
    /// was announcing.
    func testDescribesInfiniteSilenceWithoutTrapping() {
        XCTAssertEqual(TranscriptionController.describe(.infinity), "nothing transcribed today")
    }

    func testDescribesFiniteSilenceInSeconds() {
        XCTAssertEqual(TranscriptionController.describe(312), "312s")
    }
}

/// The 📬 menu item's title.
final class FluxInboxMenuTests: XCTestCase {

    func testNeverCheckedAndNothingLaunched() {
        XCTAssertEqual(FluxInboxMenu.title(lastCheck: nil, launches: 0),
                       "📬 Check task inbox")
    }

    func testShowsAgeAndRocketCount() {
        let now = Date()
        XCTAssertEqual(
            FluxInboxMenu.title(lastCheck: now.addingTimeInterval(-60), now: now, launches: 2),
            "📬 Check task inbox (1m ago, 2🚀)")
    }

    func testOmitsZeroRockets() {
        let now = Date()
        XCTAssertEqual(
            FluxInboxMenu.title(lastCheck: now.addingTimeInterval(-300), now: now, launches: 0),
            "📬 Check task inbox (5m ago)")
    }

    func testRocketsWithoutACheckYet() {
        XCTAssertEqual(FluxInboxMenu.title(lastCheck: nil, launches: 3),
                       "📬 Check task inbox (3🚀)")
    }

    func testAgeBuckets() {
        XCTAssertEqual(FluxInboxMenu.ago(0), "just now")
        XCTAssertEqual(FluxInboxMenu.ago(59), "just now")
        XCTAssertEqual(FluxInboxMenu.ago(60), "1m ago")
        XCTAssertEqual(FluxInboxMenu.ago(59 * 60), "59m ago")
        XCTAssertEqual(FluxInboxMenu.ago(3600), "1h ago")
        XCTAssertEqual(FluxInboxMenu.ago(25 * 3600), "1d ago")
    }
}
