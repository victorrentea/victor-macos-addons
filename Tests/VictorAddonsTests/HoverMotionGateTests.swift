import XCTest
@testable import VictorAddons

final class HoverMotionGateTests: XCTestCase {
    private let step: TimeInterval = 0.1   // BottomLeftBanner's dwell tick

    /// Feed `ticks` samples 0.1s apart, all at the same spot. Returns the verdicts.
    private func verdicts(positions: [CGPoint]) -> [Bool] {
        var gate = HoverMotionGate(position: positions[0], now: 0)
        return positions.enumerated().dropFirst().map { i, p in
            gate.admit(position: p, now: Double(i) * step)
        }
    }

    func testMotionlessCursorIsRejectedOnceTheWindowCloses() {
        let parked = [CGPoint](repeating: CGPoint(x: 100, y: 10), count: 8)
        let out = verdicts(positions: parked)
        // First half-second slice still open → admitted.
        XCTAssertEqual(out.prefix(4), [true, true, true, true])
        // The slice closes at 0.5s with no movement in it → rejected.
        XCTAssertFalse(out[4])
    }

    func testMovingCursorKeepsBeingAdmitted() {
        var positions = [CGPoint]()
        for i in 0..<21 { positions.append(CGPoint(x: 100 + Double(i) * 5, y: 10)) }
        XCTAssertTrue(verdicts(positions: positions).allSatisfy { $0 })
    }

    func testOneWiggleAndThenParkedFailsTheNextSlice() {
        var positions = [CGPoint(x: 100, y: 10)]
        positions.append(CGPoint(x: 120, y: 10))            // moved inside slice 1
        for _ in 0..<12 { positions.append(CGPoint(x: 120, y: 10)) }  // then parked
        let out = verdicts(positions: positions)
        XCTAssertTrue(out[4])       // slice 1 contained a move
        XCTAssertFalse(out[9])      // slice 2 did not
    }

    func testJitterBelowThresholdDoesNotCountAsMovement() {
        var positions = [CGPoint(x: 100, y: 10)]
        // 1px twitches back and forth — under `minMoveDistance`.
        for i in 1...8 { positions.append(CGPoint(x: 100 + Double(i % 2), y: 10)) }
        XCTAssertFalse(verdicts(positions: positions)[4])
    }

    func testGateReArmsAfterAFailedSlice() {
        var gate = HoverMotionGate(position: .zero, now: 0)
        XCTAssertFalse(gate.admit(position: .zero, now: 0.5))         // parked slice
        XCTAssertTrue(gate.admit(position: CGPoint(x: 50, y: 0), now: 0.6))
        XCTAssertTrue(gate.admit(position: CGPoint(x: 100, y: 0), now: 1.0))
    }

    func testSlowContinuousDragQualifies() {
        // 5pt per tick: never a big jump, but always moving.
        var positions = [CGPoint]()
        for i in 0..<21 { positions.append(CGPoint(x: Double(i) * 5, y: 300)) }
        XCTAssertTrue(verdicts(positions: positions).allSatisfy { $0 })
    }
}
