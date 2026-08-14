import XCTest
@testable import VictorAddons

final class TranscriptLadderTests: XCTestCase {

    // MARK: sentences

    func testSplitsOnTerminators() {
        XCTAssertEqual(TranscriptLadder.sentences(in: "One. Two! Three?"),
                       ["One.", "Two!", "Three?"])
    }

    func testKeepsRunsOfTerminatorsTogether() {
        XCTAssertEqual(TranscriptLadder.sentences(in: "Really?! Yes… ok."),
                       ["Really?!", "Yes…", "ok."])
    }

    func testNewlinesEndASentence() {
        // The model sometimes lays the minute out as paragraphs instead of prose.
        XCTAssertEqual(TranscriptLadder.sentences(in: "First para\nSecond para"),
                       ["First para", "Second para"])
    }

    func testKeepsAnUnterminatedTail() {
        // Whisper's last chunk is regularly cut mid-sentence; dropping it would
        // throw away exactly the newest words the feature exists to capture.
        XCTAssertEqual(TranscriptLadder.sentences(in: "Done. and then I was saying"),
                       ["Done.", "and then I was saying"])
    }

    func testEmptyTextHasNoSentences() {
        XCTAssertTrue(TranscriptLadder.sentences(in: "   \n  ").isEmpty)
    }

    // MARK: counts

    func testShortInputsGetOneRungPerSentence() {
        XCTAssertEqual(TranscriptLadder.counts(sentenceCount: 3, rungs: 5), [1, 2, 3])
        XCTAssertEqual(TranscriptLadder.counts(sentenceCount: 1, rungs: 5), [1])
    }

    func testNoSentencesMeansNoRungs() {
        XCTAssertEqual(TranscriptLadder.counts(sentenceCount: 0, rungs: 5), [])
    }

    func testLadderIsGeometricNotEven() {
        // The point of the spacing: rung 1 is "just the end", the top rung is
        // "all of it", and evenly spaced rungs would make four of the five mean
        // "most of it".
        let counts = TranscriptLadder.counts(sentenceCount: 20, rungs: 5)
        XCTAssertEqual(counts.first, 1)
        XCTAssertEqual(counts.last, 20)
        XCTAssertLessThan(counts[1], 20 / 5)  // second rung well under an even split
    }

    func testInvariantsHoldForEverySize() {
        for n in 1...200 {
            let counts = TranscriptLadder.counts(sentenceCount: n, rungs: 5)
            XCTAssertEqual(counts.count, min(n, 5), "n=\(n)")
            XCTAssertEqual(counts.first, 1, "n=\(n)")
            XCTAssertEqual(counts.last, n, "n=\(n)")
            XCTAssertEqual(counts, counts.sorted(), "n=\(n) not increasing")
            XCTAssertEqual(Set(counts).count, counts.count, "n=\(n) has duplicates")
        }
    }

    func testWorksForOtherRungCounts() {
        for rungs in 1...8 {
            let counts = TranscriptLadder.counts(sentenceCount: 40, rungs: rungs)
            XCTAssertEqual(counts.count, rungs)
            XCTAssertEqual(counts.last, 40)
            XCTAssertEqual(Set(counts).count, counts.count)
        }
    }

    // MARK: rungs

    func testEveryRungEndsOnTheNewestWords() {
        // The property the whole picker rests on. Derived here rather than asked
        // of the model precisely so it cannot fail.
        let text = "A one. B two. C three. D four. E five. F six. G seven. H eight."
        let rungs = TranscriptLadder.rungs(from: text)
        for rung in rungs {
            XCTAssertTrue(rung.hasSuffix("H eight."), "rung did not end at the end: \(rung)")
        }
    }

    func testRungsGrowAndContainTheOnesBeforeThem() {
        let text = (1...12).map { "Sentence \($0)." }.joined(separator: " ")
        let rungs = TranscriptLadder.rungs(from: text)
        XCTAssertEqual(rungs.count, 5)
        for (shorter, longer) in zip(rungs, rungs.dropFirst()) {
            XCTAssertLessThan(shorter.count, longer.count)
            XCTAssertTrue(longer.hasSuffix(shorter), "rung is not a suffix-extension of the previous")
        }
        XCTAssertEqual(rungs.first, "Sentence 12.")
        XCTAssertEqual(rungs.last, text)
    }

    func testASingleSentenceYieldsOneRung() {
        XCTAssertEqual(TranscriptLadder.rungs(from: "Just the one thing."), ["Just the one thing."])
    }

    func testEmptyTextYieldsNoRungs() {
        XCTAssertTrue(TranscriptLadder.rungs(from: "").isEmpty)
    }
}
