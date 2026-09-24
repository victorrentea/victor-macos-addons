import XCTest
@testable import VictorAddons

/// The clip must land on the **built-in Retina** whatever macOS calls the main
/// display: at a venue the ASUS is deliberately primary (origin 0,0) and the
/// Retina, mirrored to the projector, sits at -1920,0. `NSScreen.main` and
/// `screens[0]` both follow the ASUS there — which is exactly where the clip
/// played on 2026-09-24.
final class VideoPlayerScreenTests: XCTestCase {
    typealias S = VideoPlayer.ScreenCandidate

    /// The room rig on 2026-09-24, in `NSScreen.screens` order: ASUS main at
    /// index 0, the Built-in at 1, the projector (mirroring it) at 2.
    private let venue = [
        S(isBuiltIn: false, name: "ASUS MB166C", isMain: true),
        S(isBuiltIn: true, name: "Built-in Display", isMain: false),
        S(isBuiltIn: false, name: "PT-VZ585NE", isMain: false),
    ]

    func testBuiltInWinsOverTheMainASUS() {
        XCTAssertEqual(VideoPlayer.pickScreen(venue), 1)
    }

    func testBuiltInWinsEvenWhenListedLast() {
        XCTAssertEqual(VideoPlayer.pickScreen(Array(venue.reversed())), 1)
    }

    func testNameSaysBuiltInWhenTheFlagDoesNot() {
        let screens = [
            S(isBuiltIn: false, name: "ASUS MB166C", isMain: true),
            S(isBuiltIn: false, name: "Built-in Retina Display", isMain: false),
        ]
        XCTAssertEqual(VideoPlayer.pickScreen(screens), 1)
    }

    func testLidClosedFallsBackToMain() {
        // Clamshell: no built-in panel at all, the ASUS and the projector only.
        let screens = [
            S(isBuiltIn: false, name: "PT-VZ585NE", isMain: false),
            S(isBuiltIn: false, name: "ASUS MB166C", isMain: true),
        ]
        XCTAssertEqual(VideoPlayer.pickScreen(screens), 1)
    }

    func testNoMainFallsBackToFirst() {
        XCTAssertEqual(VideoPlayer.pickScreen([S(isBuiltIn: false, name: "X", isMain: false)]), 0)
    }

    func testNoScreensIsNil() {
        XCTAssertNil(VideoPlayer.pickScreen([]))
    }
}

/// The sidecar subtitles a clip may carry, parsed in-process now that no
/// external player reads them.
final class SRTSubtitlesTests: XCTestCase {
    func testParsesCuesAndStripsTags() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        Hello <i>there</i>

        2
        00:00:03,000 --> 00:00:04,000
        Two
        lines

        """
        let cues = SRTSubtitles.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0], SRTSubtitles.Cue(start: 1, end: 2.5, text: "Hello there"))
        XCTAssertEqual(cues[1].text, "Two\nlines")
    }

    func testLookupIsHalfOpen() {
        let cues = SRTSubtitles.parse("1\n00:00:01,000 --> 00:00:02,000\nA\n")
        XCTAssertNil(SRTSubtitles.text(at: 0.5, in: cues))
        XCTAssertEqual(SRTSubtitles.text(at: 1.0, in: cues), "A")
        XCTAssertNil(SRTSubtitles.text(at: 2.0, in: cues))
    }

    func testTimestampWithHoursAndDot() {
        XCTAssertEqual(SRTSubtitles.seconds("01:02:03.250"), 3723.25)
        XCTAssertNil(SRTSubtitles.seconds("02:03"))
    }
}
