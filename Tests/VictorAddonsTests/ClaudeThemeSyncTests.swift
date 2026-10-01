import XCTest
@testable import VictorAddons

final class ClaudeThemeSyncTests: XCTestCase {

    /// Claude Code only accepts the file if it is a JSON object whose `base` is
    /// one of its built-in theme names; anything else falls back to `dark`.
    func testContentsIsJsonWithTheMatchingBase() throws {
        for (isDark, base) in [(true, "dark"), (false, "light")] {
            let data = Data(ClaudeThemeSync.contents(isDark: isDark).utf8)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["base"] as? String, base)
            XCTAssertNotNil(json["overrides"] as? [String: Any])
        }
    }

    func testFileNameMatchesTheSlugTheSettingPointsAt() {
        XCTAssertEqual(ClaudeThemeSync.themeFile.lastPathComponent, "follow-macos.json")
        XCTAssertEqual(ClaudeThemeSync.themeFile.deletingLastPathComponent().lastPathComponent, "themes")
    }
}
