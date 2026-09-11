import XCTest

@testable import VictorAddons

/// The corpus switch has one job the raw switch does not: it stays on for
/// months, so the thing most worth pinning down is that it reports *honestly*
/// while it does — an "on" row whose counter is stuck reads exactly like a
/// collector that has quietly stopped.
final class VoiceCorpusRecordingTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-corpus-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testOffByDefaultAndThePythonDefaultStands() {
        XCTAssertFalse(VoiceCorpusRecording.isEnabled(in: folder))
        // Empty, not `["WHISPER_VOICE_CORPUS": "0"]` — exactly one place is
        // allowed to define "off", and it is the runner's own default.
        XCTAssertTrue(VoiceCorpusRecording.env(for: folder).isEmpty)
    }

    func testArmingWritesTheFlagAndTheEnvironment() {
        XCTAssertTrue(VoiceCorpusRecording.set(true, in: folder))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VoiceCorpusRecording.flagURL(in: folder).path))
        XCTAssertEqual(VoiceCorpusRecording.env(for: folder), ["WHISPER_VOICE_CORPUS": "1"])

        XCTAssertFalse(VoiceCorpusRecording.set(false, in: folder))
        XCTAssertNil(VoiceCorpusRecording.env(for: folder)["WHISPER_VOICE_CORPUS"])
    }

    func testItIsASeparateSwitchFromTheRawCapture() {
        // The two collect different things for different lengths of time, and
        // an accidental shared flag would mean arming a workshop's raw capture
        // silently turns on a months-long corpus, or the reverse.
        VoiceCorpusRecording.set(true, in: folder)
        XCTAssertFalse(RawAudioRecording.isEnabled(in: folder))
        XCTAssertNotEqual(
            VoiceCorpusRecording.flagURL(in: folder), RawAudioRecording.flagURL(in: folder))
    }

    func testTheDestinationFollowsTheEnvironmentSoAnExternalDiskIsOneSetting() {
        let external = VoiceCorpusRecording.corpusFolder(environment: [
            "VOICE_CORPUS_DIR": "/Volumes/Corpus/voice"
        ])
        XCTAssertEqual(external.path, "/Volumes/Corpus/voice/mic")

        let fallback = VoiceCorpusRecording.corpusFolder(environment: [:])
        XCTAssertTrue(fallback.path.hasSuffix(".walkie-talkie/voice-corpus/mic"), fallback.path)
    }

    func testTheRowCountsSpeechForTheDayAndIgnoresOtherDays() throws {
        let mic = folder.appendingPathComponent("mic")
        try FileManager.default.createDirectory(at: mic, withIntermediateDirectories: true)
        let manifest = """
            {"id":"10-00-00-mic001","wav":"2026-09-11/10-00-00-mic001.wav","seconds":30.0}
            {"id":"10-01-00-mic002","wav":"2026-09-11/10-01-00-mic002.wav","seconds":90.0}
            {"id":"09-00-00-mic003","wav":"2026-09-10/09-00-00-mic003.wav","seconds":600.0}

            """
        try manifest.write(
            to: mic.appendingPathComponent("mic-corpus.jsonl"), atomically: true, encoding: .utf8)

        var day = DateComponents()
        day.year = 2026
        day.month = 9
        day.day = 11
        let date = try XCTUnwrap(Calendar.current.date(from: day))
        let stats = VoiceCorpusRecording.collected(
            day: date, environment: ["VOICE_CORPUS_DIR": folder.path])

        XCTAssertEqual(stats.samples, 2)
        XCTAssertEqual(stats.minutes, 2.0, accuracy: 0.001)
    }

    func testAMissingManifestReadsAsZeroRatherThanCrashing() {
        // The first minutes after arming, and every fresh disk: the flag is on
        // and nothing has been written yet. That is the normal state, not an
        // error state.
        let stats = VoiceCorpusRecording.collected(
            environment: ["VOICE_CORPUS_DIR": folder.path])
        XCTAssertEqual(stats.samples, 0)
        XCTAssertEqual(stats.minutes, 0)
    }
}
