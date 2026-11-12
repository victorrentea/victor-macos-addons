import XCTest
@testable import VictorAddons

/// 💬 What the ♪ soundtrack-only play sends Victor Effects to sing.
final class VideoSoundtrackCaptionsTests: XCTestCase {
    private let cues = SRTSubtitles.parse("""
    1
    00:00:10,000 --> 00:00:11,500
    Already going.

    2
    00:00:12,000 --> 00:00:13,000
    Mayday! Mayday!

    3
    00:00:21,500 --> 00:00:22,000
    Too close to the fade.

    4
    00:00:30,000 --> 00:00:31,000
    Long gone.
    """)

    func testOnlyTheWordsOfThePlayWindowOnTheSoundtracksClock() {
        let heard = VideoSoundtrackPlayer.window(cues, startSeconds: 11)
        XCTAssertEqual(heard.map(\.text), ["Already going.", "Mayday! Mayday!"])
        XCTAssertEqual(heard[0].at, 0)            // under way at the start: what is left of it
        XCTAssertEqual(heard[0].end, 0.5, accuracy: 1e-9)
        XCTAssertEqual(heard[1].at, 1, accuracy: 1e-9)
    }

    func testThePathCarriesTheCuesAsJSONTheEffectsAppReads() throws {
        let path = try XCTUnwrap(VideoSoundtrackPlayer.captionPath(id: "KLSdOY-6R_U", cues: cues, startSeconds: 11))
        XCTAssertTrue(path.hasPrefix("/caption/video/KLSdOY-6R_U?cues="))
        let comps = try XCTUnwrap(URLComponents(string: "http://x" + path))
        let json = try XCTUnwrap(comps.queryItems?.first { $0.name == "cues" }?.value)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["text"] as? String }, ["Already going.", "Mayday! Mayday!"])
        XCTAssertEqual(rows[1]["at"] as? Double, 1)
    }

    func testNoWordsInTheWindowSendsNothing() {
        XCTAssertNil(VideoSoundtrackPlayer.captionPath(id: "x", cues: cues, startSeconds: 40))
    }
}
