import Foundation

enum DarkModeToggle {
    static func toggle() {
        guard let currentlyDark = queryDarkMode() else {
            overlayError("Failed to read current dark mode state")
            return
        }

        let targetDark = !currentlyDark
        let setScript = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(targetDark ? "true" : "false")"
        guard AppleScriptRunner.run(setScript) != nil else {
            overlayError("Failed to set dark mode")
            return
        }

        if queryDarkMode() == targetDark {
            overlayInfo(targetDark ? "Entered dark mode" : "Exited dark mode")
        } else {
            overlayError("Dark mode state did not change")
        }
    }

    static func isDark() -> Bool {
        return queryDarkMode() ?? false
    }

    private static func queryDarkMode() -> Bool? {
        let result = AppleScriptRunner.run(
            "tell application \"System Events\" to tell appearance preferences to get dark mode"
        )
        guard let normalized = result?.lowercased() else { return nil }
        if normalized == "true" { return true }
        if normalized == "false" { return false }
        return nil
    }
}
