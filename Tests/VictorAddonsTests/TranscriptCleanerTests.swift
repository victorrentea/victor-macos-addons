import XCTest
@testable import VictorAddons

/// Only the reply-tidying is covered; the Ollama round trip itself is exercised
/// live through `GET /test/transcript-picker`.
final class TranscriptCleanerTests: XCTestCase {

    func testLeavesACleanReplyAlone() {
        XCTAssertEqual(TranscriptCleaner.strip("Asta am spus. Și asta."),
                       "Asta am spus. Și asta.")
    }

    func testStripsACodeFence() {
        // A small model told to output only the text wraps it in ``` often
        // enough, and the backticks would go on the clipboard verbatim.
        let reply = """
        ```
        the cleaned text
        ```
        """
        XCTAssertEqual(TranscriptCleaner.strip(reply), "the cleaned text")
    }

    func testStripsAShortLeadIn() {
        XCTAssertEqual(TranscriptCleaner.strip("Here is the cleaned text:\nthe actual words"),
                       "the actual words")
    }

    func testKeepsASentenceThatMerelyEndsInAColon() {
        // Real speech ends a sentence with a colon often enough. Eating a
        // genuine line is worse than leaving a stray preamble the eye can see.
        let long = "The rule I always give people about this, and I mean always, is the following:"
        XCTAssertEqual(TranscriptCleaner.strip(long + "\nnever push on friday"),
                       long + "\nnever push on friday")
    }

    func testKeepsAColonLineThatIsTheWholeReply() {
        // Nothing follows it, so it IS the content — there is nothing it could
        // be a lead-in to.
        XCTAssertEqual(TranscriptCleaner.strip("asta e:"), "asta e:")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(TranscriptCleaner.strip("\n\n  words  \n\n"), "words")
    }

    func testDefaultModelIsTheOneThatDoesNotSummarize() {
        // qwen2.5 returned a third-person summary on the same window; a summary
        // is the one output this feature must never produce.
        XCTAssertEqual(TranscriptCleaner.defaultModel, "gemma3:4b")
    }
}
