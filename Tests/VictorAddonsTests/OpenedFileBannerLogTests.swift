import XCTest
@testable import VictorAddons

final class OpenedFileBannerLogTests: XCTestCase {

    private let now: Double = 800_000_000
    private let repoA = "https://github.com/victorrentea/petclinic"
    private let repoB = "https://github.com/victorrentea/spring"

    private func id(_ url: String, _ file: String) -> String? {
        OpenedFileBannerLog.identity(url: url, file: file)
    }

    // MARK: - Identity: the same pair the daemon upserts on

    /// `file` is repo-relative, so the repo has to be part of the key: the
    /// daemon keeps `petclinic/pom.xml` and `spring/pom.xml` as two rows, and
    /// the banner must not mute the second one.
    func testSamePathInAnotherRepoIsADifferentFile() {
        var seen: [String: Double] = [:]
        var announce: Bool
        (announce, seen) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "pom.xml"), now: now)
        XCTAssertTrue(announce)
        (announce, _) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoB, "pom.xml"), now: now + 1)
        XCTAssertTrue(announce)
    }

    /// One repo, however it was written in the git remote — matching
    /// `files_md._canonical_repo_url`.
    func testRemoteUrlSpellingsCollapseToOneRepo() {
        let canonical = id(repoA, "pom.xml")
        XCTAssertEqual(id("git@github.com:victorrentea/petclinic.git", "pom.xml"), canonical)
        XCTAssertEqual(id("https://github.com/victorrentea/petclinic.git", "pom.xml"), canonical)
        XCTAssertEqual(id("https://github.com/victorrentea/petclinic/", "pom.xml"), canonical)
        XCTAssertEqual(id("https://GitHub.com/victorrentea/petclinic", "pom.xml"), canonical)
    }

    /// A remote carrying more than owner/repo (a self-hosted path, a stray
    /// suffix) still resolves to the same repo the daemon would record.
    func testExtraPathSegmentsAreDropped() {
        XCTAssertEqual(id("https://github.com/victorrentea/petclinic/tree/main", "pom.xml"),
                       id(repoA, "pom.xml"))
    }

    /// The sentinel the editors send when a project is open with no file
    /// selected — the daemon drops it, and `📄 (none)` is not worth a flash.
    func testTheNoFileSentinelIsNeverAnnounced() {
        let (announce, updated) = OpenedFileBannerLog.decide(
            seen: [:], identity: id(repoA, OpenedFileBannerLog.noFileSentinel), now: now)
        XCTAssertFalse(announce)
        XCTAssertTrue(updated.isEmpty)
        XCTAssertNil(id(repoA, ""))
        XCTAssertNil(id(repoA, "   "))
    }

    // MARK: - The muting itself

    /// The complaint that started this: A, then B, then back to A. Only the
    /// first sighting of each file may reach the banner.
    func testGoingBackToAnEarlierFileStaysSilent() {
        var seen: [String: Double] = [:]
        var announce: Bool

        (announce, seen) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/A.java"), now: now)
        XCTAssertTrue(announce)
        (announce, seen) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/B.java"), now: now + 5)
        XCTAssertTrue(announce)
        (announce, seen) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/A.java"), now: now + 10)
        XCTAssertFalse(announce)
        (announce, _) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/B.java"), now: now + 15)
        XCTAssertFalse(announce)
    }

    /// Same basename in two modules of one repo is still two files — the banner
    /// shows only the last path component, but the memory must not collapse them.
    func testSameNameInAnotherFolderIsANewFile() {
        var seen: [String: Double] = [:]
        (_, seen) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "api/pom.xml"), now: now)
        let (announce, _) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "web/pom.xml"), now: now + 1)
        XCTAssertTrue(announce)
    }

    func testTheMemoryExpiresSoTomorrowStartsClean() {
        var seen: [String: Double] = [:]
        (_, seen) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/A.java"), now: now)

        let justBefore = now + OpenedFileBannerLog.repeatAfter - 60
        XCTAssertFalse(OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/A.java"),
                                                  now: justBefore).announce)

        let nextDay = now + OpenedFileBannerLog.repeatAfter + 60
        XCTAssertTrue(OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/A.java"),
                                                 now: nextDay).announce)
    }

    /// A stamp from the future (a bad clock after wake) must not mute a file
    /// forever: it announces once and the entry heals to the current time.
    func testAFutureStampHealsInsteadOfMutingForever() {
        let key = id(repoA, "src/A.java")!
        let (announce, updated) = OpenedFileBannerLog.decide(
            seen: [key: now + 10 * 3600], identity: key, now: now)
        XCTAssertTrue(announce)
        XCTAssertEqual(updated[key], now)
    }

    /// The log bounds itself, keeping the newest paths — the ones still likely
    /// to be re-opened.
    func testPruningKeepsTheNewestEntries() {
        var seen: [String: Double] = [:]
        for i in 0..<40 {
            (_, seen) = OpenedFileBannerLog.decide(seen: seen, identity: id(repoA, "src/f\(i).java"),
                                                   now: now + Double(i), maxEntries: 10)
        }
        XCTAssertEqual(seen.count, 10)
        XCTAssertNotNil(seen[id(repoA, "src/f39.java")!])
        XCTAssertNil(seen[id(repoA, "src/f0.java")!])
    }

    /// Entries past the horizon are dropped on the next write, so a machine
    /// left running for weeks doesn't carry a plist of dead paths.
    func testExpiredEntriesAreDroppedOnWrite() {
        let old = id(repoA, "src/old.java")!
        let (_, updated) = OpenedFileBannerLog.decide(
            seen: [old: now], identity: id(repoA, "src/new.java"),
            now: now + OpenedFileBannerLog.repeatAfter + 60)
        XCTAssertNil(updated[old])
        XCTAssertNotNil(updated[id(repoA, "src/new.java")!])
    }
}
