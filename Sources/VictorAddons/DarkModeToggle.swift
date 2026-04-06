import Foundation

enum DarkModeToggle {
    static func toggle() {
        AppleScriptRunner.run(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        )
        overlayInfo("Toggled dark mode")
    }

    static func isDark() -> Bool {
        let result = AppleScriptRunner.run(
            "tell application \"System Events\" to tell appearance preferences to get dark mode"
        )
        return result?.lowercased() == "true"
    }
}
