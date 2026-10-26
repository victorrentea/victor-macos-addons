import XCTest
@testable import VictorAddons

/// The switch behind the 🔊 Zoom Share Prep row. Two things are worth pinning
/// down, and both are about a wrong answer that would ship in silence.
final class ZoomSharePrepSettingsTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ZoomSharePrepSettings.enabledKey)
        super.tearDown()
    }

    /// `UserDefaults.bool(forKey:)` answers false for a key nobody has written,
    /// which would turn the prep off for everyone on the first launch after this
    /// switch was added — and nothing would report it: a share picker that
    /// simply does nothing looks exactly like Zoom behaving normally.
    func testDefaultsOnWithNothingStored() {
        UserDefaults.standard.removeObject(forKey: ZoomSharePrepSettings.enabledKey)
        XCTAssertTrue(ZoomSharePrepSettings.isEnabled)
    }

    func testSettingSurvivesAsWritten() {
        ZoomSharePrepSettings.isEnabled = false
        XCTAssertFalse(ZoomSharePrepSettings.isEnabled)

        ZoomSharePrepSettings.isEnabled = true
        XCTAssertTrue(ZoomSharePrepSettings.isEnabled)
    }

    /// The instance property is a window onto the stored setting, not a copy of
    /// it. A cached mirror is the failure this design avoids: the menu tick and
    /// the running scan must never be able to disagree.
    func testInstancePropertyReadsAndWritesTheStoredSetting() {
        let prep = ZoomSharePrep()

        ZoomSharePrepSettings.isEnabled = false
        XCTAssertFalse(prep.isEnabled)

        prep.isEnabled = true
        XCTAssertTrue(ZoomSharePrepSettings.isEnabled)
    }
}
