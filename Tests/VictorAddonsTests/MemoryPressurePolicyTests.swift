import XCTest
@testable import VictorAddons

final class MemoryPressurePolicyTests: XCTestCase {

    private func sample(decompressions: UInt64, swapins: UInt64,
                        cpu: MemoryPressurePolicy.CPUTicks = .unknown,
                        atSecond second: TimeInterval)
        -> MemoryPressurePolicy.Sample {
        MemoryPressurePolicy.Sample(decompressions: decompressions, swapins: swapins, cpu: cpu,
                                    at: Date(timeIntervalSince1970: second))
    }

    /// Most verdict tests care about one number at a time; a CPU pinned at 100
    /// keeps the gate open so the other threshold is what is under test.
    private func rates(decompressionsPerSec: Double, swapinsPerSec: Double,
                       cpuBusyPercent: Double = 100) -> MemoryPressurePolicy.Rates {
        MemoryPressurePolicy.Rates(decompressionsPerSec: decompressionsPerSec,
                                   swapinsPerSec: swapinsPerSec,
                                   cpuBusyPercent: cpuBusyPercent)
    }

    // MARK: - Rates

    func testRatesAreCountsPerSecond() {
        let previous = sample(decompressions: 1_000, swapins: 10, atSecond: 0)
        let current = sample(decompressions: 6_000, swapins: 110, atSecond: 5)
        let rates = MemoryPressurePolicy.Rates.between(previous, current)
        XCTAssertEqual(rates?.decompressionsPerSec ?? 0, 1_000, accuracy: 0.001)
        XCTAssertEqual(rates?.swapinsPerSec ?? 0, 20, accuracy: 0.001)
    }

    func testCpuBusyPercentIsTheNonIdleShare() {
        let previous = sample(decompressions: 0, swapins: 0,
                              cpu: .init(busy: 1_000, total: 2_000), atSecond: 0)
        let current = sample(decompressions: 0, swapins: 0,
                             cpu: .init(busy: 1_750, total: 3_000), atSecond: 5)
        let rates = MemoryPressurePolicy.Rates.between(previous, current)
        XCTAssertEqual(rates?.cpuBusyPercent ?? 0, 75, accuracy: 0.001)
    }

    /// A CPU read that failed or stood still must not be the thing that
    /// silences the plate, so it scores as fully busy and leaves the decision
    /// to the compressor threshold alone.
    func testUnreadableCpuCountsAsFullyBusy() {
        let previous = sample(decompressions: 0, swapins: 0, cpu: .unknown, atSecond: 0)
        let current = sample(decompressions: 0, swapins: 0, cpu: .unknown, atSecond: 5)
        XCTAssertEqual(MemoryPressurePolicy.Rates.between(previous, current)?.cpuBusyPercent, 100)

        // Same for ticks that went backwards across a reboot.
        let after = sample(decompressions: 0, swapins: 0,
                           cpu: .init(busy: 10, total: 20), atSecond: 5)
        let before = sample(decompressions: 0, swapins: 0,
                            cpu: .init(busy: 5_000, total: 9_000), atSecond: 0)
        XCTAssertEqual(MemoryPressurePolicy.Rates.between(before, after)?.cpuBusyPercent, 100)
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

    /// The rate actually measured on this Mac while `kernel_task` sat at 31%
    /// and the cores had nothing left to give.
    func testMeasuredThrashIsHurting() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 1_000, swapinsPerSec: 1, cpuBusyPercent: 95)), .hurting)
    }

    /// Measured 2026-09-18: 353 decompressions/s with 53% of the CPU idle and
    /// the machine feeling fine. The compressor working is not the complaint.
    func testBusyCompressorWithIdleCoresIsCalm() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 353, swapinsPerSec: 0, cpuBusyPercent: 47)), .calm)
    }

    /// Even full-thrash compressor rates say nothing while there are cycles to
    /// spare — that is the whole point of the CPU gate.
    func testHeavyCompressorWithIdleCoresIsStillCalm() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 1_000, swapinsPerSec: 0, cpuBusyPercent: 50)), .calm)
    }

    /// A CPU in its own hysteresis band is as inconclusive as a rate in the
    /// compressor's band: the plate keeps whatever it had.
    func testCpuInItsBandChangesNothing() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 1_000, swapinsPerSec: 0, cpuBusyPercent: 70)), .unchanged)
    }

    /// A saturated CPU on its own is just work getting done — the compressor
    /// has to be in it too.
    func testBusyCpuWithAQuietCompressorIsCalm() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 5, swapinsPerSec: 0, cpuBusyPercent: 99)), .calm)
    }

    /// The same session's swap-file counters: 0 swapouts, ~1 swapin/s. A rule
    /// built on swapping alone would have called this calm.
    func testSwapFileAloneWouldHaveMissedIt() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 0, swapinsPerSec: 1)), .calm)
    }

    func testHeavySwapInIsHurtingEvenWithAQuietCompressor() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 0, swapinsPerSec: 60)), .hurting)
    }

    /// Swapping is a stall on disk, not a cycle cost, so idle cores are no
    /// consolation and the CPU gate does not apply to it.
    func testHeavySwapInIsHurtingEvenOnAnIdleCpu() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 0, swapinsPerSec: 60, cpuBusyPercent: 5)), .hurting)
    }

    func testIdleMachineIsCalm() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 3, swapinsPerSec: 0, cpuBusyPercent: 4)), .calm)
    }

    func testHysteresisBandChangesNothing() {
        XCTAssertEqual(MemoryPressurePolicy.verdict(
            for: rates(decompressionsPerSec: 250, swapinsPerSec: 0)), .unchanged)
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

    /// The load easing while the compressor stays busy is the way this plate
    /// goes out most often — the CPU half clearing has to be enough.
    func testTheAlarmEndsWhenTheCpuFreesUpEvenIfTheCompressorDoesNot() {
        var tracker = MemoryPressurePolicy.Tracker(isHurting: true)
        let easing = rates(decompressionsPerSec: 1_000, swapinsPerSec: 0, cpuBusyPercent: 40)
        tracker.accept(MemoryPressurePolicy.verdict(for: easing))
        tracker.accept(MemoryPressurePolicy.verdict(for: easing))
        XCTAssertTrue(tracker.accept(MemoryPressurePolicy.verdict(for: easing)))
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

    /// The Mach calls have to work on the machine running the tests; the numbers
    /// are whatever they are, but they must be readable and must move forward.
    func testCountersCanBeReadFromTheKernel() throws {
        let first = try XCTUnwrap(MemoryPressureMonitor.readCounters(),
                                  "host_statistics64(HOST_VM_INFO64) failed")
        let second = try XCTUnwrap(MemoryPressureMonitor.readCounters(now: first.at.addingTimeInterval(1)))
        XCTAssertGreaterThan(first.decompressions, 0)
        XCTAssertGreaterThanOrEqual(second.decompressions, first.decompressions)
        XCTAssertGreaterThanOrEqual(second.swapins, first.swapins)
    }

    /// `HOST_CPU_LOAD_INFO` has to answer too, or every sample would score as
    /// fully busy and the gate would be decorative.
    func testCpuTicksCanBeReadFromTheKernel() {
        let first = MemoryPressureMonitor.readCPUTicks()
        XCTAssertNotEqual(first, .unknown, "host_statistics(HOST_CPU_LOAD_INFO) failed")
        XCTAssertGreaterThan(first.total, first.busy, "an idle counter of zero means the read is wrong")
        let second = MemoryPressureMonitor.readCPUTicks()
        XCTAssertGreaterThanOrEqual(second.total, first.total)
    }
}
