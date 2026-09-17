import XCTest
@testable import VictorAddons

final class MemoryPressurePolicyTests: XCTestCase {

    private func sample(decompressions: UInt64, swapins: UInt64, atSecond second: TimeInterval)
        -> MemoryPressurePolicy.Sample {
        MemoryPressurePolicy.Sample(decompressions: decompressions, swapins: swapins,
                                    at: Date(timeIntervalSince1970: second))
    }

    // MARK: - Rates

    func testRatesAreCountsPerSecond() {
        let previous = sample(decompressions: 1_000, swapins: 10, atSecond: 0)
        let current = sample(decompressions: 6_000, swapins: 110, atSecond: 5)
        let rates = MemoryPressurePolicy.Rates.between(previous, current)
        XCTAssertEqual(rates?.decompressionsPerSec ?? 0, 1_000, accuracy: 0.001)
        XCTAssertEqual(rates?.swapinsPerSec ?? 0, 20, accuracy: 0.001)
    }

    func testNoRateForAZeroOrBackwardsInterval() {
        let a = sample(decompressions: 1_000, swapins: 10, atSecond: 10)
        let b = sample(decompressions: 2_000, swapins: 20, atSecond: 10)
        XCTAssertNil(MemoryPressurePolicy.Rates.between(a, b))
        let earlier = sample(decompressions: 2_000, swapins: 20, atSecond: 5)
        XCTAssertNil(MemoryPressurePolicy.Rates.between(a, earlier))
    }

    /// Counters only go backwards across a reboot, which is the one moment the
    /// machine is certainly not under pressure — a negative delta must not be
    /// read as a huge unsigned one.
    func testCountersGoingBackwardsYieldNoRate() {
        let previous = sample(decompressions: 5_000, swapins: 100, atSecond: 0)
        let current = sample(decompressions: 10, swapins: 1, atSecond: 5)
        XCTAssertNil(MemoryPressurePolicy.Rates.between(previous, current))
    }

    // MARK: - Verdicts

    /// The rate actually measured on this Mac while `kernel_task` sat at 31%.
    func testMeasuredThrashIsHurting() {
        let rates = MemoryPressurePolicy.Rates(decompressionsPerSec: 1_000, swapinsPerSec: 1)
        XCTAssertEqual(MemoryPressurePolicy.verdict(for: rates), .hurting)
    }

    /// The same session's swap-file counters: 0 swapouts, ~1 swapin/s. A rule
    /// built on swapping alone would have called this calm.
    func testSwapFileAloneWouldHaveMissedIt() {
        let rates = MemoryPressurePolicy.Rates(decompressionsPerSec: 0, swapinsPerSec: 1)
        XCTAssertEqual(MemoryPressurePolicy.verdict(for: rates), .calm)
    }

    func testHeavySwapInIsHurtingEvenWithAQuietCompressor() {
        let rates = MemoryPressurePolicy.Rates(decompressionsPerSec: 0, swapinsPerSec: 60)
        XCTAssertEqual(MemoryPressurePolicy.verdict(for: rates), .hurting)
    }

    func testIdleMachineIsCalm() {
        let rates = MemoryPressurePolicy.Rates(decompressionsPerSec: 3, swapinsPerSec: 0)
        XCTAssertEqual(MemoryPressurePolicy.verdict(for: rates), .calm)
    }

    func testHysteresisBandChangesNothing() {
        let rates = MemoryPressurePolicy.Rates(decompressionsPerSec: 250, swapinsPerSec: 0)
        XCTAssertEqual(MemoryPressurePolicy.verdict(for: rates), .unchanged)
    }

    // MARK: - Sustain

    func testOneBadSampleDoesNotLightThePlate() {
        var tracker = MemoryPressurePolicy.Tracker()
        XCTAssertFalse(tracker.accept(.hurting))
        XCTAssertFalse(tracker.isHurting)
    }

    func testThreeInARowLightIt() {
        var tracker = MemoryPressurePolicy.Tracker()
        XCTAssertFalse(tracker.accept(.hurting))
        XCTAssertFalse(tracker.accept(.hurting))
        XCTAssertTrue(tracker.accept(.hurting), "third sample should flip the state")
        XCTAssertTrue(tracker.isHurting)
    }

    /// An app launch spiking the compressor for five seconds, then settling. The
    /// whole point of the sustain count.
    func testABurstThatEndsNeverLightsIt() {
        var tracker = MemoryPressurePolicy.Tracker()
        tracker.accept(.hurting)
        tracker.accept(.calm)
        tracker.accept(.hurting)
        tracker.accept(.hurting)
        tracker.accept(.calm)
        XCTAssertFalse(tracker.isHurting)
    }

    func testThreeCalmSamplesClearIt() {
        var tracker = MemoryPressurePolicy.Tracker(isHurting: true)
        XCTAssertFalse(tracker.accept(.calm))
        XCTAssertFalse(tracker.accept(.calm))
        XCTAssertTrue(tracker.accept(.calm))
        XCTAssertFalse(tracker.isHurting)
    }

    /// A rate drifting up through the hysteresis band must still get there: the
    /// band is silence, not a reset, or the streak could never complete.
    func testBandDoesNotResetTheStreak() {
        var tracker = MemoryPressurePolicy.Tracker()
        tracker.accept(.hurting)
        tracker.accept(.unchanged)
        tracker.accept(.hurting)
        tracker.accept(.unchanged)
        XCTAssertTrue(tracker.accept(.hurting))
        XCTAssertTrue(tracker.isHurting)
    }

    func testFlipIsReportedOnceNotEveryTick() {
        var tracker = MemoryPressurePolicy.Tracker()
        tracker.accept(.hurting)
        tracker.accept(.hurting)
        XCTAssertTrue(tracker.accept(.hurting))
        XCTAssertFalse(tracker.accept(.hurting), "already red — no second repaint")
        XCTAssertFalse(tracker.accept(.hurting))
    }

    // MARK: - Live counters

    /// The Mach call has to work on the machine running the tests; the numbers
    /// are whatever they are, but they must be readable and must move forward.
    func testCountersCanBeReadFromTheKernel() throws {
        let first = try XCTUnwrap(MemoryPressureMonitor.readCounters(),
                                  "host_statistics64(HOST_VM_INFO64) failed")
        let second = try XCTUnwrap(MemoryPressureMonitor.readCounters(now: first.at.addingTimeInterval(1)))
        XCTAssertGreaterThan(first.decompressions, 0)
        XCTAssertGreaterThanOrEqual(second.decompressions, first.decompressions)
        XCTAssertGreaterThanOrEqual(second.swapins, first.swapins)
    }
}
