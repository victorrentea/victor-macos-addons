import XCTest
@testable import VictorAddons

/// The `claude -p` round trip is exercised live through
/// `GET /test/transcript-picker?at=HH:MM`; what is worth pinning down here is
/// the reply parsing and the fixed slot captions.
final class TranscriptDistillerTests: XCTestCase {

    func testParsesACleanJsonReply() throws {
        let options = try TranscriptDistiller.parseOptions(#"{"options": ["punctul", "ideea"]}"#)
        XCTAssertEqual(options, ["punctul", "ideea"])
    }

    func testParsesAFencedReply() throws {
        // Sonnet answered bare JSON in testing and haiku wrapped it in a fence;
        // the model is swappable, so both have to work.
        let reply = """
        ```json
        {"options": ["a", "b"]}
        ```
        """
        XCTAssertEqual(try TranscriptDistiller.parseOptions(reply), ["a", "b"])
    }

    func testParsesAReplyWithProseAroundIt() throws {
        let reply = "Here you go:\n{\"options\": [\"a\", \"b\"]}\nHope that helps."
        XCTAssertEqual(try TranscriptDistiller.parseOptions(reply), ["a", "b"])
    }

    func testTrimsAndDropsBlanks() throws {
        XCTAssertEqual(try TranscriptDistiller.parseOptions(#"{"options": ["  x  ", "", "  "]}"#), ["x"])
    }

    func testDropsDuplicateOptions() throws {
        // Two slots that compress to the same words are a choice with no
        // difference, and they push a genuinely different one off the panel.
        XCTAssertEqual(try TranscriptDistiller.parseOptions(#"{"options": ["same", "same", "other"]}"#),
                       ["same", "other"])
    }

    func testIgnoresNonStringEntries() throws {
        XCTAssertEqual(try TranscriptDistiller.parseOptions(#"{"options": ["ok", 42, null]}"#), ["ok"])
    }

    func testRejectsRepliesWithNothingUsable() {
        // Failing loudly gets the Basso and a log line; an empty modal would
        // read as a bug with no message.
        XCTAssertThrowsError(try TranscriptDistiller.parseOptions("I could not do that."))
        XCTAssertThrowsError(try TranscriptDistiller.parseOptions(#"{"choices": ["a"]}"#))
        XCTAssertThrowsError(try TranscriptDistiller.parseOptions(#"{"options": []}"#))
    }

    func testAProseRefusalIsQuotedBackInTheError() {
        // When the model answers in prose it is *saying why*; swallowing that
        // turns a legible refusal into a mystery in the log.
        XCTAssertThrowsError(try TranscriptDistiller.parseOptions(
            "There is nothing here to distill — the transcript is a single word.")) { error in
            XCTAssertTrue("\(error)".contains("nothing here to distill"), "\(error)")
        }
    }

    // MARK: too little speech

    func testCountsSpeechWordsIgnoringTheStamps() {
        // Counting the raw line would score a `[HH:MM]` per line and make a
        // window of eight grunts look substantial.
        XCTAssertEqual(TranscriptDistiller.speechWordCount(in: "[09:05] one two three"), 3)
        XCTAssertEqual(TranscriptDistiller.speechWordCount(in: "[09:05] a b\n[09:06] c"), 3)
        XCTAssertEqual(TranscriptDistiller.speechWordCount(in: "no stamp here"), 3)
        XCTAssertEqual(TranscriptDistiller.speechWordCount(in: ""), 0)
    }

    func testTheSingleWordWindowFallsUnderTheThreshold() {
        // The case that found this: pressed after a lull, the window came down
        // to "Da!" and the model answered with a sentence the parser could only
        // report as a failure — twelve seconds to be told what a word count knew.
        XCTAssertLessThan(TranscriptDistiller.speechWordCount(in: "[22:05] Da!"),
                          TranscriptDistiller.minWordsWorthDistilling)
        XCTAssertGreaterThanOrEqual(
            TranscriptDistiller.speechWordCount(in: "[22:05] " + Array(repeating: "word", count: 12).joined(separator: " ")),
            TranscriptDistiller.minWordsWorthDistilling)
    }

    // MARK: slot captions

    func testTheSevenSlotsAreTheSevenThingsVictorActuallyReachesFor() {
        // Fixed in Swift rather than asked of the model: the shape is the same
        // every run, so the caption under each row never drifts and the hand can
        // learn "the agent prompt is the fifth one".
        XCTAssertEqual(TranscriptDistiller.kinds.count, 7)
        XCTAssertEqual(TranscriptDistiller.kind(at: 0), "the point — one line")
        XCTAssertEqual(TranscriptDistiller.kind(at: 2), "the funny line")
        XCTAssertEqual(TranscriptDistiller.kind(at: 3), "the emotional anchor")
        XCTAssertEqual(TranscriptDistiller.kind(at: 4), "agent-ready prompt")
        XCTAssertEqual(TranscriptDistiller.kind(at: 6), "everything, dense")
    }

    func testEverySlotIsDigitReachable() {
        // The digit shortcuts only go to 9, and the badge falls back to a bare
        // "·" past that — seven rows all stay pressable.
        XCTAssertLessThanOrEqual(TranscriptDistiller.kinds.count, 9)
    }

    func testAnExtraOptionGetsNoCaptionRatherThanAWrongOne() {
        // The model occasionally returns eight; captioning the eighth with the
        // seventh's label would be a confident lie about what the row is.
        XCTAssertNil(TranscriptDistiller.kind(at: 7))
        XCTAssertNil(TranscriptDistiller.kind(at: -1))
    }

    func testTwoLineBudgetIsWhatFitsThePanel() {
        // The panel is scanned, not read: seven rows that each need a paragraph
        // of attention is not a menu, it is homework.
        XCTAssertEqual(TranscriptDistiller.maxCharsPerOption, 180)
    }

    func testModelDefaultsToSonnet() {
        // Measured on the same minute: sonnet 13 s, haiku 17 s — the weaker
        // model spends more output tokens saying the same thing.
        guard ProcessInfo.processInfo.environment["TRANSCRIPT_DISTILL_MODEL"] == nil else { return }
        XCTAssertEqual(TranscriptDistiller.model, "sonnet")
    }
}
