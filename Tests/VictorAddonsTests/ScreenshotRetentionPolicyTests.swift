import XCTest
@testable import VictorAddons

final class ScreenshotRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mb = 1024 * 1024

    private func item(_ name: String, daysAgo: Double, mb sizeMB: Int = 1) -> ScreenshotRetentionPolicy.Item {
        .init(name: name, modified: now.addingTimeInterval(-daysAgo * 24 * 3600), bytes: sizeMB * mb)
    }

    func testEmptyFolderDeletesNothing() {
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete([], now: now), [])
    }

    func testRecentShotsAreKept() {
        let items = [item("a", daysAgo: 0), item("b", daysAgo: 3), item("c", daysAgo: 13.9)]
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now), [])
    }

    func testShotsPastTheAgeLimitGo() {
        let items = [item("fresh", daysAgo: 1), item("old", daysAgo: 20), item("ancient", daysAgo: 90)]
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now), ["old", "ancient"])
    }

    /// The capture taken one second ago must survive a wrong clock — that is the
    /// file the user is about to paste.
    func testNewestSurvivesEvenWhenItselfExpired() {
        let items = [item("only", daysAgo: 400)]
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now), [])
    }

    func testNewestSurvivesEvenWhenAloneOverTheSizeCap() {
        let items = [item("huge", daysAgo: 0, mb: 50)]
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now, maxBytes: 1 * 1024 * 1024), [])
    }

    func testSizeCapDropsOldestFirst() {
        let items = [item("newest", daysAgo: 0, mb: 4),
                     item("middle", daysAgo: 1, mb: 4),
                     item("oldest", daysAgo: 2, mb: 4)]
        // 10 MB cap: newest (4) + middle (8) fit, oldest (12) does not.
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now, maxBytes: 10 * 1024 * 1024),
                       ["oldest"])
    }

    /// A single oversized file in the middle must not evict everything after it —
    /// only what genuinely does not fit is dropped.
    func testOversizedMiddleFileDoesNotDoomSmallerOlderOnes() {
        let items = [item("newest", daysAgo: 0, mb: 1),
                     item("whale", daysAgo: 1, mb: 100),
                     item("small", daysAgo: 2, mb: 1)]
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now, maxBytes: 10 * 1024 * 1024),
                       ["whale"])
    }

    func testAgeAndSizeCapsCombine() {
        let items = [item("newest", daysAgo: 0, mb: 4),
                     item("stale", daysAgo: 30, mb: 1),
                     item("bulky", daysAgo: 1, mb: 4),
                     item("bulkier", daysAgo: 2, mb: 4)]
        // newest (4) + bulky (8) fit; bulkier busts the 10 MB cap, stale is expired.
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now, maxBytes: 10 * 1024 * 1024),
                       ["bulkier", "stale"])
    }

    func testFutureDatedFileIsTreatedAsNewestAndKept() {
        let items = [.init(name: "future", modified: now.addingTimeInterval(3600), bytes: mb),
                     item("today", daysAgo: 0)]
        XCTAssertEqual(ScreenshotRetentionPolicy.toDelete(items, now: now), [])
    }
}
