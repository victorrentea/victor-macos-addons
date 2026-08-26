import XCTest
@testable import VictorAddons

/// Raw capture is armed for one session and must be unmistakably off the rest of
/// the time. These pin the two ways that could quietly stop being true: the flag
/// not surviving a relaunch, and the environment claiming a state the disk does
/// not agree with.
final class RawAudioRecordingTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-audio-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testOffByDefaultEvenWhenTheFolderDoesNotExistYet() {
        XCTAssertFalse(RawAudioRecording.isEnabled(in: folder))
        XCTAssertTrue(RawAudioRecording.env(for: folder).isEmpty)
    }

    func testArmingCreatesTheFolderAndSurvivesRereading() {
        // The app is restarted constantly (build, deploy, watchdog). If the flag
        // did not outlive the process it would be worthless for a whole day of
        // teaching.
        XCTAssertTrue(RawAudioRecording.set(true, in: folder))
        XCTAssertTrue(RawAudioRecording.isEnabled(in: folder))
        XCTAssertEqual(RawAudioRecording.env(for: folder), ["WHISPER_RECORD_RAW": "1"])
    }

    func testClearingRemovesIt() {
        RawAudioRecording.set(true, in: folder)
        XCTAssertFalse(RawAudioRecording.set(false, in: folder))
        XCTAssertFalse(RawAudioRecording.isEnabled(in: folder))
        XCTAssertTrue(RawAudioRecording.env(for: folder).isEmpty)
    }

    func testClearingSomethingAlreadyOffIsNotAnError() {
        XCTAssertFalse(RawAudioRecording.set(false, in: folder))
    }

    func testEnvIsEmptyRatherThanZeroWhenOff() {
        // One place decides what "off" means — the runner's own default. An
        // explicit "0" here would be a second one, free to drift.
        XCTAssertTrue(RawAudioRecording.env(for: folder).isEmpty)
    }

    func testHoursRecordedCountsOnlyTodaysFiles() throws {
        let dir = RawAudioRecording.audioFolder(in: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())

        // Half an hour of 16 kHz mono int16.
        let halfHour = Int(RawAudioRecording.bytesPerSecond * 1800)
        try Data(count: halfHour).write(to: dir.appendingPathComponent("\(today)-Victor.s16le16k.pcm"))
        try Data(count: halfHour).write(to: dir.appendingPathComponent("2001-01-01-Victor.s16le16k.pcm"))

        XCTAssertEqual(RawAudioRecording.hoursRecorded(in: folder), 0.5, accuracy: 0.001)
    }

    func testHoursRecordedIsZeroWithNoRecordings() {
        XCTAssertEqual(RawAudioRecording.hoursRecorded(in: folder), 0, accuracy: 0.0001)
    }

    func testTheMenuRowNamesTheStateNotJustTheAction() {
        // The row exists to make an invisible state visible, so "on" must not
        // read like a button you could press.
        XCTAssertFalse(MenuBarManager.RawAudioMenu.off.contains("🔴"))
        XCTAssertTrue(MenuBarManager.RawAudioMenu.on(hours: 0).contains("🔴"))
        XCTAssertTrue(MenuBarManager.RawAudioMenu.on(hours: 2.5).contains("2.5"))
    }
}
