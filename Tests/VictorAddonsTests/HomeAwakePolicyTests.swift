import XCTest
@testable import VictorAddons

/// 🏠 Home Wi-Fi keeps the screen on — the decision, without a radio.
final class HomeAwakePolicyTests: XCTestCase {

    private let home = ["tzutze"]

    func testOnTheHomeNetworkHoldsTheDisplayAwake() {
        XCTAssertTrue(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: "tzutze", homeSSIDs: home))
    }

    func testOnAnotherNetworkDoesNot() {
        XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: "Devoxx UK 2026", homeSSIDs: home))
    }

    /// The leak this feature must not have. CoreWLAN answers nil for Wi-Fi off,
    /// no interface and withheld Location Services — none of which is evidence
    /// of being at home, and all of which would otherwise pin the display awake
    /// with nothing left to release it.
    func testUnknownSSIDIsNotHome() {
        XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: nil, homeSSIDs: home))
        XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: "", homeSSIDs: home))
    }

    func testDisarmedNeverHolds() {
        XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: false, ssid: "tzutze", homeSSIDs: home))
    }

    /// The band-siblings sit in this Mac's preferred list next to the real one.
    /// They are separate networks and only count if the config says so — a
    /// prefix match would adopt all four without anyone deciding to.
    func testBandSiblingsAreNotTheHomeNetworkUnlessConfigured() {
        for other in ["tzutze5", "tzutze2.4", "tzutze_5G"] {
            XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
                enabled: true, ssid: other, homeSSIDs: home), other)
        }
        XCTAssertTrue(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: "tzutze5", homeSSIDs: ["tzutze", "tzutze5"]))
    }

    /// SSIDs are case-sensitive on the wire, and so is this.
    func testMatchIsExactNotCaseFolded() {
        XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: "TZUTZE", homeSSIDs: home))
    }

    /// Victor says "Țuțe"; the network is not called that. The spoken name must
    /// not match, or the feature would appear to work while matching nothing.
    func testTheSpokenNameIsNotTheSSID() {
        XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: "Țuțe", homeSSIDs: home))
    }

    // MARK: - Config parsing

    func testParsesACommaSeparatedListAndToleratesSpacing() {
        XCTAssertEqual(HomeAwakePolicy.parseSSIDs("tzutze"), ["tzutze"])
        XCTAssertEqual(HomeAwakePolicy.parseSSIDs("tzutze, tzutze5"), ["tzutze", "tzutze5"])
        XCTAssertEqual(HomeAwakePolicy.parseSSIDs("  tzutze ,,  tzutze_5G  ,"),
                       ["tzutze", "tzutze_5G"])
    }

    /// An emptied setting disarms the matching rather than matching everything.
    func testEmptyConfigMatchesNothing() {
        XCTAssertEqual(HomeAwakePolicy.parseSSIDs("   "), [])
        XCTAssertFalse(HomeAwakePolicy.shouldHoldDisplayAwake(
            enabled: true, ssid: "tzutze", homeSSIDs: HomeAwakePolicy.parseSSIDs("")))
    }

    /// An SSID with a space in it survives the split — plenty in the preferred
    /// list have one, and trimming must not eat the inner space.
    func testSSIDWithSpacesSurvives() {
        XCTAssertEqual(HomeAwakePolicy.parseSSIDs("tzutze, Villa Le Ortensie"),
                       ["tzutze", "Villa Le Ortensie"])
    }

    /// The shipped default is the string actually read off this Mac's interface
    /// on 13 Sep 2026, not the phonetic spelling of it.
    func testDefaultIsTheMeasuredSSID() {
        XCTAssertEqual(HomeAwakePolicy.parseSSIDs(HomeAwakeSettings.defaultSSIDs), ["tzutze"])
    }
}
