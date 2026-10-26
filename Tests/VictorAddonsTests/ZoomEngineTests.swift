import XCTest
@testable import VictorAddons

final class ZoomEngineTests: XCTestCase {

    /// Replays flagsChanged states (option, shift, command, control) at the given times.
    private func feed(_ steps: [(Bool, Bool, Bool, Bool, TimeInterval)], into tap: inout OptionShiftTap) -> [Bool] {
        steps.map { tap.flagsChanged(option: $0.0, shift: $0.1, command: $0.2, control: $0.3, at: $0.4) }
    }

    func testOptionThenShiftTappedFlips() {
        var tap = OptionShiftTap()
        let fired = feed([(true, false, false, false, 0.00), (true, true, false, false, 0.05),
                          (false, true, false, false, 0.15), (false, false, false, false, 0.20)], into: &tap)
        XCTAssertEqual(fired, [false, false, false, true])
    }

    func testShiftThenOptionTappedFlipsToo() {
        var tap = OptionShiftTap()
        let fired = feed([(false, true, false, false, 0.00), (true, true, false, false, 0.04),
                          (false, false, false, false, 0.12)], into: &tap)
        XCTAssertEqual(fired.last, true)
    }

    /// Holding ⌥⇧ is the emoji cheat-sheet; a hold is not a tap.
    func testHoldDoesNotFlip() {
        var tap = OptionShiftTap()
        let fired = feed([(true, true, false, false, 0.00), (false, false, false, false, 0.80)], into: &tap)
        XCTAssertEqual(fired.last, false)
    }

    func testOptionAloneOrShiftAloneDoesNotFlip() {
        var tap = OptionShiftTap()
        XCTAssertEqual(feed([(true, false, false, false, 0), (false, false, false, false, 0.1)], into: &tap).last, false)
        XCTAssertEqual(feed([(false, true, false, false, 1), (false, false, false, false, 1.1)], into: &tap).last, false)
    }

    /// ⌥⇧-typing a character: the keystroke in between spoils the tap.
    func testKeyTypedInBetweenDoesNotFlip() {
        var tap = OptionShiftTap()
        _ = feed([(true, true, false, false, 0)], into: &tap)
        tap.interrupt()
        XCTAssertEqual(feed([(false, false, false, false, 0.1)], into: &tap).last, false)
        // …and the next clean tap still works.
        XCTAssertEqual(feed([(true, true, false, false, 1), (false, false, false, false, 1.1)], into: &tap).last, true)
    }

    func testCommandJoiningSpoilsIt() {
        var tap = OptionShiftTap()
        let fired = feed([(true, true, false, false, 0), (true, true, true, false, 0.05),
                          (false, false, true, false, 0.1), (false, false, false, false, 0.15)], into: &tap)
        XCTAssertFalse(fired.contains(true))
    }

    func testEngineToggles() {
        XCTAssertEqual(ZoomEngine.system.toggled, .share)
        XCTAssertEqual(ZoomEngine.share.toggled, .system)
    }
}
