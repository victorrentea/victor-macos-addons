import XCTest
@testable import VictorAddons

/// 🎬 A new voice starts a new caption line: where the batch correction's
/// diarization says the voice changes, as indices of the words the band splits.
final class LiveCaptionsSpeakerTests: XCTestCase {

    private func word(_ text: String, _ who: String) -> [String: Any] {
        ["text": text, "type": "word", "speaker_id": who]
    }
    private func space(_ who: String) -> [String: Any] {
        ["text": " ", "type": "spacing", "speaker_id": who]
    }

    /// The shape of the real reply (two `say` voices, 2026-10-14), shortened.
    func testFindsEachChangeOfVoice() {
        let json: [String: Any] = ["text": "ignored", "words": [
            word("the", "speaker_0"), space("speaker_0"), word("list.", "speaker_0"), space("speaker_0"),
            word("Wait,", "speaker_1"), space("speaker_1"), word("here?", "speaker_1"), space("speaker_1"),
            word("Exactly,", "speaker_0"), space("speaker_0"), word("query", "speaker_0"),
        ]]
        let reply = LiveCaptionsStream.speakerStarts(json)
        XCTAssertEqual(reply?.0, "the list. Wait, here? Exactly, query")
        XCTAssertEqual(reply?.1, [2, 4])
    }

    func testOneVoiceHasNoBreak() {
        let json: [String: Any] = ["words": [word("one", "speaker_0"), space("speaker_0"), word("voice", "speaker_0")]]
        XCTAssertEqual(LiveCaptionsStream.speakerStarts(json)?.1, [])
    }

    func testWithoutWordsFallsBackToText() {
        let reply = LiveCaptionsStream.speakerStarts(["text": " plain text \n"])
        XCTAssertEqual(reply?.0, "plain text")
        XCTAssertEqual(reply?.1, [])
    }

    /// A word glued to the previous one has no space to break at.
    func testAGluedWordIsNoBreak() {
        let json: [String: Any] = ["words": [word("N", "speaker_0"), word("+1", "speaker_1")]]
        XCTAssertEqual(LiveCaptionsStream.speakerStarts(json)?.1, [])
    }

    /// Leading spacing is trimmed from the text and does not shift the index.
    func testLeadingSpaceDoesNotShiftTheIndex() {
        let json: [String: Any] = ["words": [space("speaker_0"), word("yes", "speaker_0"), space("speaker_0"),
                                              word("no", "speaker_1")]]
        let reply = LiveCaptionsStream.speakerStarts(json)
        XCTAssertEqual(reply?.0, "yes no")
        XCTAssertEqual(reply?.1, [1])
    }
}
