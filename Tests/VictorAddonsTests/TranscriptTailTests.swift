import XCTest
@testable import VictorAddons

final class TranscriptTailTests: XCTestCase {

    // MARK: parse

    func testParsesStampedLines() {
        let lines = TranscriptTail.parse("""
        [09:05] first thing
        [09:06] second thing
        """)
        XCTAssertEqual(lines, [
            TranscriptTail.Line(minuteOfDay: 9 * 60 + 5, text: "first thing"),
            TranscriptTail.Line(minuteOfDay: 9 * 60 + 6, text: "second thing"),
        ])
    }

    func testDropsDeviceMarkersAndBlanks() {
        // The marker lines whisper writes on every mic switch carry no stamp;
        // reading one as speech is what used to keep the 😶 warning quiet.
        let lines = TranscriptTail.parse("""
        --- Victor → 💻 ---

        [09:05] real speech
        """)
        XCTAssertEqual(lines.map(\.text), ["real speech"])
    }

    func testDropsAHalfSlicedFirstLine() {
        // A 64 KB tail starts mid-line far more often than not.
        let lines = TranscriptTail.parse("ceva taiat la jumatate\n[09:05] intact")
        XCTAssertEqual(lines.map(\.text), ["intact"])
    }

    func testSpeakerPrefixesAreJustText() {
        // Old files still carry `Victor 🎙️:` prefixes. They must not crash or
        // vanish — they are simply part of the line now.
        let lines = TranscriptTail.parse("[09:05] Victor 🎙️: hello")
        XCTAssertEqual(lines.map(\.text), ["Victor 🎙️: hello"])
    }

    // MARK: lastMinutes

    func testWindowIsAnchoredOnTheNewestLineNotOnNow() {
        // The whole point: whisper stamps late, so anchoring on the wall clock
        // would empty the window exactly when Victor has just stopped talking.
        let lines = TranscriptTail.parse("""
        [09:00] way back
        [09:04] older
        [09:05] newer
        [09:06] newest
        """)
        let window = TranscriptTail.lastMinutes(lines, windowMinutes: 1)
        XCTAssertEqual(window.map(\.text), ["newer", "newest"])
    }

    func testWindowKeepsEverythingWhenItIsWideEnough() {
        let lines = TranscriptTail.parse("[09:00] a\n[09:01] b")
        XCTAssertEqual(TranscriptTail.lastMinutes(lines, windowMinutes: 5).count, 2)
    }

    func testLinesStampedAfterTheAnchorAreDroppedAsPreMidnight() {
        // A day file can open with a `[23:5x]` line from just before midnight;
        // `anchor - line` goes negative there and must not read as "recent".
        let lines = TranscriptTail.parse("[23:59] yesterday\n[00:01] today")
        let window = TranscriptTail.lastMinutes(lines, windowMinutes: 1)
        XCTAssertEqual(window.map(\.text), ["today"])
    }

    func testEmptyInputYieldsEmptyWindow() {
        XCTAssertTrue(TranscriptTail.lastMinutes([], windowMinutes: 1).isEmpty)
    }

    // MARK: render

    func testRenderRoundTrips() {
        let text = "[09:05] one\n[09:06] two"
        XCTAssertEqual(TranscriptTail.render(TranscriptTail.parse(text)), text)
    }

    func testRenderZeroPadsTheStamp() {
        XCTAssertEqual(TranscriptTail.render([TranscriptTail.Line(minuteOfDay: 65, text: "x")]),
                       "[01:05] x")
    }

    // MARK: file access

    func testReadTailReturnsTheEndOfALongFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = TranscriptTail.todayFile(in: dir)
        let filler = String(repeating: "[08:00] filler line that is here only to push past the tail window\n",
                            count: 3000)
        try (filler + "[09:06] the newest thing\n").write(to: file, atomically: true, encoding: .utf8)

        XCTAssertGreaterThan(TranscriptTail.size(of: file), 65_536)
        let parsed = TranscriptTail.parse(TranscriptTail.readTail(of: file))
        XCTAssertEqual(parsed.last?.text, "the newest thing")
        XCTAssertEqual(TranscriptTail.lastMinutes(parsed, windowMinutes: 1).map(\.text),
                       ["the newest thing"])
    }

    func testSizeOfMissingFileIsZero() {
        let missing = URL(fileURLWithPath: "/nope/\(UUID().uuidString).txt")
        XCTAssertEqual(TranscriptTail.size(of: missing), 0)
        XCTAssertEqual(TranscriptTail.readTail(of: missing), "")
    }
}
