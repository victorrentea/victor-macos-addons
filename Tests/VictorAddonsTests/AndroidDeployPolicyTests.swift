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

    // MARK: - Which device is the tablet

    private func dev(_ serial: String, _ model: String, _ chars: String) -> AndroidDeployPolicy.Device {
        AndroidDeployPolicy.Device(serial: serial, model: model, characteristics: chars)
    }

    /// The regression this was written for: the phone on the cable used to be
    /// treated as "the adb device" and got the tablet's app installed on it.
    func testPhoneAloneIsNotATablet() {
        let phone = dev("RZCX50DX0GM", "SM_S928B", "phone")
        guard case .none(let why) = AndroidDeployPolicy.pickTablet([phone]) else {
            return XCTFail("the phone must never be picked as the tablet")
        }
        XCTAssertTrue(why.contains("SM_S928B"), "the reason should name what was seen: \(why)")
    }

    func testTabletIsPickedByItsOwnCharacteristics() {
        let tablet = dev("HA1ABCDE", "TB350FU", "tablet,nosdcard")
        XCTAssertEqual(AndroidDeployPolicy.pickTablet([tablet]), .tablet(tablet))
    }

    /// Both on the cable at once: the tablet still wins, and adb is no longer
    /// left to pick (it would refuse with "more than one device").
    func testTabletIsPickedOutOfAMixedSet() {
        let tablet = dev("HA1ABCDE", "TB350FU", "tablet")
        let phone = dev("RZCX50DX0GM", "SM_S928B", "phone")
        XCTAssertEqual(AndroidDeployPolicy.pickTablet([phone, tablet]), .tablet(tablet))
    }

    /// A tablet that doesn't declare itself is still recognised by model.
    func testModelFallbackForASilentTablet() {
        let tablet = dev("HA1ABCDE", "TB350FU", "")
        XCTAssertEqual(AndroidDeployPolicy.pickTablet([tablet]), .tablet(tablet))
    }

    func testNothingAttached() {
        guard case .none = AndroidDeployPolicy.pickTablet([]) else {
            return XCTFail("no devices means no tablet")
        }
    }

    /// The regression that arrived with wireless debugging: ONE tablet listing
    /// itself three times (cable, ip:port, mDNS name) used to read as three
    /// tablets and stop the auto-deploy dead — a silent failure, since the
    /// passive path never notifies.
    func testOneTabletOnSeveralTransportsIsStillOneTablet() {
        let usb = wired("HVA5HP4L", "TB350FU", "tablet", hw: "HVA5HP4L")
        let ip = wired("192.168.101.66:40633", "TB350FU", "tablet", hw: "HVA5HP4L")
        let mdns = wired("adb-HVA5HP4L-b2mjKy._adb-tls-connect._tcp", "TB350FU", "tablet", hw: "HVA5HP4L")
        XCTAssertEqual(AndroidDeployPolicy.pickTablet([usb, ip, mdns]), .tablet(usb),
                       "one physical tablet on three transports is one tablet")
    }

    /// And when only the wireless doors are open, it still deploys — over one of
    /// them rather than refusing.
    func testWirelessOnlyTabletIsDeployable() {
        let ip = wired("192.168.101.66:40633", "TB350FU", "tablet", hw: "HVA5HP4L")
        let mdns = wired("adb-HVA5HP4L-b2mjKy._adb-tls-connect._tcp", "TB350FU", "tablet", hw: "HVA5HP4L")
        guard case .tablet = AndroidDeployPolicy.pickTablet([ip, mdns]) else {
            return XCTFail("a tablet reachable only over WiFi is still the tablet")
        }
    }

    /// The cable wins when both are up: faster for a 25 MB APK, and the venue's
    /// access point can't drop it mid-install.
    func testCableIsPreferredOverWireless() {
        let ip = wired("192.168.101.66:40633", "TB350FU", "tablet", hw: "HVA5HP4L")
        let usb = wired("HVA5HP4L", "TB350FU", "tablet", hw: "HVA5HP4L")
        XCTAssertEqual(AndroidDeployPolicy.pickTablet([ip, usb]), .tablet(usb))
    }

    /// Two genuinely different tablets must still refuse: the dedupe is by
    /// hardware serial, not by "they both look like tablets".
    func testTwoDistinctTabletsStillRefuse() {
        let a = wired("A", "TB350FU", "tablet", hw: "HVA5HP4L")
        let b = wired("B", "TB350FU", "tablet", hw: "OTHER123")
        guard case .none = AndroidDeployPolicy.pickTablet([a, b]) else {
            return XCTFail("two different tablets must not be resolved by guessing")
        }
    }

    private func wired(_ serial: String, _ model: String, _ chars: String, hw: String) -> AndroidDeployPolicy.Device {
        AndroidDeployPolicy.Device(serial: serial, model: model, characteristics: chars, hardwareSerial: hw)
    }

    /// Two candidates is ambiguity, and guessing is how the phone got the app in
    /// the first place — refuse and say so.
    func testTwoTabletsRefuseRatherThanGuess() {
        let a = dev("A", "TB350FU", "tablet")
        let b = dev("B", "TB351XU", "tablet")
        guard case .none(let why) = AndroidDeployPolicy.pickTablet([a, b]) else {
            return XCTFail("two tablets must not be resolved by guessing")
        }
        XCTAssertTrue(why.contains("VICTOR_TABLET_SERIAL"), "the reason should say how to break the tie: \(why)")
    }
}
