import XCTest
@testable import VictorAddons

final class AndroidDeployPolicyTests: XCTestCase {
    private let tz = TimeZone(identifier: "Europe/Bucharest")!
    /// 4 Aug 2026, 19:41 local (Bucharest, UTC+3).
    private let buildDate = Date(timeIntervalSince1970: 1785861660)

    private func clean(_ commit: String = "abc1234") -> AndroidDeployPolicy.SourceState {
        .init(commit: commit, dirty: false, changedAt: buildDate)
    }

    private func dirty(_ commit: String = "abc1234") -> AndroidDeployPolicy.SourceState {
        .init(commit: commit, dirty: true, changedAt: buildDate)
    }

    // MARK: - stamp

    func testCleanTreeIsIdentifiedByItsCommitAlone() {
        XCTAssertEqual(clean().stamp, "abc1234")
    }

    func testDirtyTreeCarriesTheEditTimestampSoEverySaveIsANewStamp() {
        let first = dirty()
        let later = AndroidDeployPolicy.SourceState(
            commit: "abc1234", dirty: true, changedAt: buildDate.addingTimeInterval(60))
        XCTAssertNotEqual(first.stamp, later.stamp)
        XCTAssertTrue(first.stamp.hasPrefix("abc1234+local-"))
    }

    func testStampSurvivesAMissingGit() {
        let s = AndroidDeployPolicy.SourceState(commit: "", dirty: false, changedAt: buildDate)
        XCTAssertEqual(s.stamp, "nogit")
    }

    // MARK: - shouldDeploy

    func testMatchingStampDeploysNothing() {
        let s = clean()
        XCTAssertFalse(AndroidDeployPolicy.shouldDeploy(source: s, deviceStamp: s.stamp))
    }

    func testTrailingNewlineFromAdbShellStillMatches() {
        let s = clean()
        XCTAssertFalse(AndroidDeployPolicy.shouldDeploy(source: s, deviceStamp: "\(s.stamp)\r\n"))
    }

    func testNewCommitDeploys() {
        XCTAssertTrue(AndroidDeployPolicy.shouldDeploy(source: clean("def5678"), deviceStamp: "abc1234"))
    }

    func testUncommittedEditOnTheDeployedCommitStillDeploys() {
        XCTAssertTrue(AndroidDeployPolicy.shouldDeploy(source: dirty(), deviceStamp: "abc1234"))
    }

    func testMissingMarkerDeploysToEstablishABaseline() {
        XCTAssertTrue(AndroidDeployPolicy.shouldDeploy(source: clean(), deviceStamp: nil))
        XCTAssertTrue(AndroidDeployPolicy.shouldDeploy(source: clean(), deviceStamp: ""))
        XCTAssertTrue(AndroidDeployPolicy.shouldDeploy(source: clean(), deviceStamp: "   \n"))
    }

    // MARK: - notification wording

    func testSuccessBodyLeadsWithTheBuildDateThenTheCommit() {
        XCTAssertEqual(
            AndroidDeployPolicy.successBody(source: clean(), timeZone: tz),
            "4 Aug 2026, 19:41 · abc1234"
        )
    }

    func testSuccessBodyMarksAnUncommittedBuild() {
        XCTAssertEqual(
            AndroidDeployPolicy.successBody(source: dirty(), timeZone: tz),
            "4 Aug 2026, 19:41 · abc1234+local"
        )
    }

    func testSuccessBodyIsJustTheDateWithoutGit() {
        let s = AndroidDeployPolicy.SourceState(commit: "", dirty: false, changedAt: buildDate)
        XCTAssertEqual(AndroidDeployPolicy.successBody(source: s, timeZone: tz), "4 Aug 2026, 19:41")
    }

    func testFailureBodyNamesTheStepAndKeepsTheDate() {
        XCTAssertEqual(
            AndroidDeployPolicy.failureBody(
                step: "gradle assembleDebug", detail: "  > compileDebugKotlin FAILED \n",
                source: clean(), timeZone: tz),
            "gradle assembleDebug: > compileDebugKotlin FAILED — 4 Aug 2026, 19:41"
        )
    }

    func testFailureBodyWithoutDetailIsStillReadable() {
        XCTAssertEqual(
            AndroidDeployPolicy.failureBody(step: "adb install", detail: "", source: clean(), timeZone: tz),
            "adb install — 4 Aug 2026, 19:41"
        )
    }

    func testDateFormatIsLocaleIndependent() {
        XCTAssertEqual(AndroidDeployPolicy.describe(buildDate, timeZone: tz), "4 Aug 2026, 19:41")
    }
}
