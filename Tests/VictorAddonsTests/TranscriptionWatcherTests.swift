import XCTest
@testable import VictorAddons

/// The pure staleness decision behind the silent-transcription warning.
/// The bug it fixes: a mid-day app restart, where today's transcript file
/// already exists with an OLD mtime, used to report "stale" instantly — before
/// Whisper had even loaded its model — producing a false "no voice" warning.
/// Anchoring staleness to `max(mtime, start)` gives each (re)start a fresh
/// warm-up window while leaving steady-state detection unchanged.
final class TranscriptionWatcherTests: XCTestCase {

    private let threshold: TimeInterval = 180
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// The regression: pre-existing file from an hour ago, but Whisper just
    /// (re)started 30 s ago → still warming up, NOT stale.
    func testMidDayRestartOldFileWithinGraceNotStale() {
        let oldMtime = start.addingTimeInterval(-3600) // an hour before this start
        let now = start.addingTimeInterval(30)
        XCTAssertFalse(TranscriptionWatcher.isStale(mtime: oldMtime, start: start, now: now, threshold: threshold))
    }

    /// Same restart, but still no line 200 s later → genuinely silent, stale.
    func testMidDayRestartStillSilentPastGraceIsStale() {
        let oldMtime = start.addingTimeInterval(-3600)
        let now = start.addingTimeInterval(200)
        XCTAssertTrue(TranscriptionWatcher.isStale(mtime: oldMtime, start: start, now: now, threshold: threshold))
    }

    /// Fresh day: file doesn't exist yet, 30 s into warm-up → not stale.
    func testFreshDayNoFileWithinGraceNotStale() {
        let now = start.addingTimeInterval(30)
        XCTAssertFalse(TranscriptionWatcher.isStale(mtime: nil, start: start, now: now, threshold: threshold))
    }

    /// Steady state: a line was written 100 s after start, checked 10 s later.
    func testFreshLineAfterStartNotStale() {
        let mtime = start.addingTimeInterval(100)
        let now = start.addingTimeInterval(110)
        XCTAssertFalse(TranscriptionWatcher.isStale(mtime: mtime, start: start, now: now, threshold: threshold))
    }

    /// Steady state gone quiet: last line at +100 s, now +300 s (200 s gap) → stale.
    /// Confirms genuine mid-session silence still fires (no regression).
    func testFreshLineThenLongSilenceIsStale() {
        let mtime = start.addingTimeInterval(100)
        let now = start.addingTimeInterval(300)
        XCTAssertTrue(TranscriptionWatcher.isStale(mtime: mtime, start: start, now: now, threshold: threshold))
    }

    /// Boundary: exactly `threshold` is NOT stale (strictly greater-than fires).
    func testBoundaryAtThresholdIsNotStale() {
        let now = start.addingTimeInterval(threshold)
        XCTAssertFalse(TranscriptionWatcher.isStale(mtime: nil, start: start, now: now, threshold: threshold))
        let justOver = start.addingTimeInterval(threshold + 0.001)
        XCTAssertTrue(TranscriptionWatcher.isStale(mtime: nil, start: start, now: justOver, threshold: threshold))
    }
}
