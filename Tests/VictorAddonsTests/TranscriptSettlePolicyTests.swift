import XCTest
@testable import VictorAddons

final class TranscriptSettlePolicyTests: XCTestCase {

    private typealias P = TranscriptSettlePolicy

    func testWaitsOutTheFloorEvenWhenTheFileIsAlreadyQuiet() {
        // The failure this floor exists for: the key is pressed during a natural
        // pause, the file has not grown for a while, and whisper still has the
        // last 6 s chunk in its queue. Quiet is not the same as caught up.
        XCTAssertEqual(P.decide(elapsed: 1, sinceLastGrowth: 1), .wait)
        XCTAssertEqual(P.decide(elapsed: P.minWait - 0.01, sinceLastGrowth: 99), .wait)
    }

    func testReadyOnceThePastTheFloorAndTheFileHasGoneQuiet() {
        XCTAssertEqual(P.decide(elapsed: P.minWait, sinceLastGrowth: P.quietSeconds), .ready)
        XCTAssertEqual(P.decide(elapsed: 12, sinceLastGrowth: 5), .ready)
    }

    func testKeepsWaitingWhileLinesAreStillLanding() {
        // Growth means whisper is still draining its backlog — the newest words
        // are, by definition, not in the file yet.
        XCTAssertEqual(P.decide(elapsed: 12, sinceLastGrowth: 0.2), .wait)
        XCTAssertEqual(P.decide(elapsed: 20, sinceLastGrowth: P.quietSeconds - 0.01), .wait)
    }

    func testGivesUpAtTheCeiling() {
        // A picker that opens slightly stale beats one that never opens.
        XCTAssertEqual(P.decide(elapsed: P.maxWait, sinceLastGrowth: 0), .timedOut)
        XCTAssertEqual(P.decide(elapsed: 999, sinceLastGrowth: 0), .timedOut)
    }

    func testCeilingWinsOverEveryOtherClause() {
        XCTAssertEqual(P.decide(elapsed: P.maxWait + 1, sinceLastGrowth: 99), .timedOut)
    }

    func testAFileThatNeverGrowsSettlesAtTheFloor() {
        // Callers seed `sinceLastGrowth` with `elapsed`, so nothing-being-said
        // (or whisper being down) resolves at `minWait` rather than hanging for
        // the full ceiling with a spinner under the cursor.
        XCTAssertEqual(P.decide(elapsed: P.minWait, sinceLastGrowth: P.minWait), .ready)
    }

    func testTheFloorLeavesRoomForAWholeChunkPlusInference() {
        // WHISPER_CHUNK_SECONDS defaults to 6; a floor at or under that would
        // let the run finish before the audio containing the last word had even
        // been handed to the model.
        XCTAssertGreaterThan(P.minWait, 6)
        XCTAssertLessThan(P.minWait, P.maxWait)
        XCTAssertLessThan(P.pollInterval, P.quietSeconds)
    }
}
