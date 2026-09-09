import XCTest
@testable import VictorAddons

final class CaptionStreamTests: XCTestCase {

    // MARK: - Seaming two chunks

    func testChunksWithNothingInCommonAreSimplyJoined() {
        let merged = CaptionStream.merge(standing: "hai să vedem", incoming: "ce se întâmplă aici")
        XCTAssertEqual(merged, "hai să vedem ce se întâmplă aici")
    }

    /// The 2 s overlap, which is the whole reason this type exists: whisper
    /// transcribes the same seconds twice and neither copy knows about the other.
    func testTheOverlapIsCollapsedInsteadOfRepeated() {
        let merged = CaptionStream.merge(
            standing: "facem un refactoring pe clasa asta",
            incoming: "pe clasa asta ca să scoatem logica afară")
        XCTAssertEqual(merged, "facem un refactoring pe clasa asta ca să scoatem logica afară")
    }

    /// The point of the whole design: it is the **newer** transcription of the
    /// shared seconds that survives, because that pass heard those words with a
    /// sentence of context behind them. Here the older chunk cut "clasa" short
    /// and the newer one got it right — the band must end up showing the newer.
    func testTheNewerReadingOfTheOverlapReplacesTheOlder() {
        let merged = CaptionStream.merge(
            standing: "facem un refactoring pe clasa asta",
            incoming: "pe clasa asta, da, ca să scoatem logica")
        XCTAssertEqual(merged, "facem un refactoring pe clasa asta, da, ca să scoatem logica")
    }

    func testOverlapIsMatchedIgnoringCasePunctuationAndDiacritics() {
        let merged = CaptionStream.merge(
            standing: "și atunci intrăm în clasă.",
            incoming: "Intram in clasa și deschidem fișierul")
        XCTAssertEqual(merged, "și atunci Intram in clasa și deschidem fișierul")
    }

    /// Longest first. A three-word overlap also matches on its last two words,
    /// and stopping at that shorter hit would leave a word duplicated on screen.
    func testTheLongestOverlapWins() {
        XCTAssertEqual(
            CaptionStream.overlapWordCount(
                standing: ["deci", "hai", "să", "facem", "asta"],
                incoming: ["să", "facem", "asta", "acum"]),
            3)
    }

    // MARK: - What is deliberately *not* treated as a seam

    /// 2 s of audio is several words at any speaking pace, so a single word in
    /// common is a coincidence — and Romanian and English both end and start
    /// clauses with the same little words all day. Honouring it would delete a
    /// real word out of the middle of the sentence.
    func testASingleSharedWordIsNotASeam() {
        let merged = CaptionStream.merge(standing: "am terminat și", incoming: "și acum plecăm")
        XCTAssertEqual(merged, "am terminat și și acum plecăm")
    }

    /// Past a dozen words the match cannot be explained by a 2 s overlap: the
    /// speaker really did say it twice, and it belongs on screen twice.
    func testAVeryLongRepetitionIsLeftAlone() {
        let phrase = (1...14).map { "cuvânt\($0)" }.joined(separator: " ")
        let merged = CaptionStream.merge(standing: phrase, incoming: phrase)
        XCTAssertEqual(CaptionStream.words(merged).count, 28)
    }

    func testOverlapNeedsBothSidesToStillHaveWordsAfterFolding() {
        // Punctuation-only tokens fold away; two dashes are not an overlap.
        XCTAssertEqual(
            CaptionStream.overlapWordCount(standing: ["bine", "—", "—"], incoming: ["—", "—", "gata"]),
            0)
    }

    // MARK: - Edges

    func testEmptyIncomingLeavesTheBandAlone() {
        XCTAssertEqual(CaptionStream.merge(standing: "ceva", incoming: "   "), "ceva")
    }

    func testFirstChunkStartsTheBand() {
        XCTAssertEqual(CaptionStream.merge(standing: "", incoming: "primul lucru"), "primul lucru")
    }

    // MARK: - The window

    func testTheWindowKeepsTheNewestTextAndCutsWholeWordsOffTheFront() {
        let long = (1...200).map { "cuvânt\($0)" }.joined(separator: " ")
        let trimmed = CaptionStream.merge(standing: "", incoming: long)

        XCTAssertLessThanOrEqual(trimmed.count, CaptionStream.maxCharacters)
        XCTAssertTrue(trimmed.hasSuffix("cuvânt200"), "the newest words are the ones kept")
        // Cut on a word boundary: every surviving token is a whole word from the
        // input, so the band never opens mid-word.
        let words = Set(CaptionStream.words(long))
        XCTAssertTrue(CaptionStream.words(trimmed).allSatisfy(words.contains))
    }

    func testShortTextIsNotTrimmed() {
        XCTAssertEqual(CaptionStream.merge(standing: "", incoming: "scurt și clar"), "scurt și clar")
    }

    // MARK: - Folding

    func testFoldReturnsNilForPunctuationOnlyTokens() {
        XCTAssertNil(CaptionStream.fold("—"))
        XCTAssertNil(CaptionStream.fold("..."))
        XCTAssertEqual(CaptionStream.fold("Clasă,"), CaptionStream.fold("clasa"))
    }
}

/// The other half of the band: how far it may read a file whisper is appending to.
final class LiveCaptionsReadTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    func testWholeLinesAreConsumedWholly() {
        let result = LiveCaptions.completeLines(in: data("[09:05] unu\n[09:06] doi\n"))
        XCTAssertEqual(result?.text, "[09:05] unu\n[09:06] doi\n")
        XCTAssertEqual(result?.consumedBytes, data("[09:05] unu\n[09:06] doi\n").count)
    }

    /// A tick landing inside whisper's write must not put half a word on the
    /// projector — and must not consume the fragment either.
    func testAHalfWrittenLineIsLeftForTheNextTick() {
        let full = "[09:05] unu\n"
        let result = LiveCaptions.completeLines(in: data(full + "[09:06] jum"))
        XCTAssertEqual(result?.text, full)
        XCTAssertEqual(result?.consumedBytes, data(full).count)
    }

    func testNothingCompleteYetConsumesNothing() {
        XCTAssertNil(LiveCaptions.completeLines(in: data("[09:06] fără newline")))
        XCTAssertNil(LiveCaptions.completeLines(in: Data()))
    }

    /// The cut is on a newline, so it can never fall inside a multi-byte
    /// character — the transcript is full of diacritics and emoji.
    func testMultibyteTextSurvivesTheCut() {
        let result = LiveCaptions.completeLines(in: data("[09:05] șă î â ț 🎙️\n[09:06] parți"))
        XCTAssertEqual(result?.text, "[09:05] șă î â ț 🎙️\n")
    }
}

/// Shapes taken from a real transcript rather than invented — the speaker glyph
/// whisper has stamped on every line since 2026-08-28 is invisible in synthetic
/// fixtures and breaks both halves of the band.
final class CaptionStreamRealTranscriptTests: XCTestCase {

    func testTheSpeakerGlyphNeverReachesTheBand() {
        XCTAssertEqual(
            CaptionStream.merge(standing: "", incoming: "🎙️ The subtitle should be, please reward me"),
            "The subtitle should be, please reward me")
        XCTAssertEqual(
            CaptionStream.merge(standing: "", incoming: "👥 o întrebare din sală"),
            "o întrebare din sală")
    }

    /// With the glyph left on, the overlap starts at the *second* token of the
    /// arriving chunk and no seam is ever found — every boundary duplicates.
    func testTheGlyphDoesNotHideTheSeam() {
        // Two chunks, fed in the order the band feeds them — the second one's
        // first four words are the 2 s overlap.
        var band = CaptionStream.merge(standing: "", incoming: "🎙️ To make it more incentive for people")
        band = CaptionStream.merge(standing: band, incoming: "🎙️ incentive for people to actually give the feedback")
        XCTAssertEqual(band, "To make it more incentive for people to actually give the feedback")
    }

    /// A lone dash sitting exactly on the seam must not cost the overlap.
    func testPunctuationOnTheSeamDoesNotBreakIt() {
        let merged = CaptionStream.merge(
            standing: "deci hai să facem — asta",
            incoming: "hai să facem asta acum")
        XCTAssertEqual(merged, "deci hai să facem asta acum")
    }

    func testAnUnlabelledLineIsLeftExactlyAsWritten() {
        XCTAssertEqual(CaptionStream.merge(standing: "", incoming: "fără glif aici"), "fără glif aici")
    }
}
