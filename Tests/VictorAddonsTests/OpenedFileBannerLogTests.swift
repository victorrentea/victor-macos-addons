import XCTest
@testable import VictorAddons

final class OpenedFileBannerLogTests: XCTestCase {

    private let now: Double = 800_000_000

    /// The complaint that started this: A, then B, then back to A. Only the
    /// first sighting of each file may reach the banner.
    func testGoingBackToAnEarlierFileStaysSilent() {
        var seen: [String: Double] = [:]
        var announce: Bool

        (announce, seen) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/A.java", now: now)
        XCTAssertTrue(announce)
        (announce, seen) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/B.java", now: now + 5)
        XCTAssertTrue(announce)
        (announce, seen) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/A.java", now: now + 10)
        XCTAssertFalse(announce)
        (announce, _) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/B.java", now: now + 15)
        XCTAssertFalse(announce)
    }

    /// Same basename in two modules is two different files — the banner shows
    /// only the last path component, but the memory must not collapse them.
    func testSameNameInAnotherFolderIsANewFile() {
        var seen: [String: Double] = [:]
        (_, seen) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/api/pom.xml", now: now)
        let (announce, _) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/web/pom.xml", now: now + 1)
        XCTAssertTrue(announce)
    }

    func testTheMemoryExpiresSoTomorrowStartsClean() {
        var seen: [String: Double] = [:]
        (_, seen) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/A.java", now: now)

        let justBefore = now + OpenedFileBannerLog.repeatAfter - 60
        XCTAssertFalse(OpenedFileBannerLog.decide(seen: seen, path: "/repo/A.java", now: justBefore).announce)

        let nextDay = now + OpenedFileBannerLog.repeatAfter + 60
        XCTAssertTrue(OpenedFileBannerLog.decide(seen: seen, path: "/repo/A.java", now: nextDay).announce)
    }

    /// A stamp from the future (a bad clock after wake) must not mute a file
    /// forever: it announces once and the entry heals to the current time.
    func testAFutureStampHealsInsteadOfMutingForever() {
        let seen = ["/repo/A.java": now + 10 * 3600]
        let (announce, updated) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/A.java", now: now)
        XCTAssertTrue(announce)
        XCTAssertEqual(updated["/repo/A.java"], now)
    }

    /// The log bounds itself, keeping the newest paths — the ones still likely
    /// to be re-opened.
    func testPruningKeepsTheNewestEntries() {
        var seen: [String: Double] = [:]
        for i in 0..<40 {
            (_, seen) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/f\(i).java",
                                                   now: now + Double(i), maxEntries: 10)
        }
        XCTAssertEqual(seen.count, 10)
        XCTAssertNotNil(seen["/repo/f39.java"])
        XCTAssertNil(seen["/repo/f0.java"])
    }

    /// Entries past the horizon are dropped on the next write, so a machine
    /// left running for weeks doesn't carry a plist of dead paths.
    func testExpiredEntriesAreDroppedOnWrite() {
        let seen = ["/repo/old.java": now]
        let (_, updated) = OpenedFileBannerLog.decide(seen: seen, path: "/repo/new.java",
                                                      now: now + OpenedFileBannerLog.repeatAfter + 60)
        XCTAssertNil(updated["/repo/old.java"])
        XCTAssertNotNil(updated["/repo/new.java"])
    }

    func testAnEmptyPathIsNeverAnnounced() {
        let (announce, updated) = OpenedFileBannerLog.decide(seen: [:], path: "", now: now)
        XCTAssertFalse(announce)
        XCTAssertTrue(updated.isEmpty)
    }
}
