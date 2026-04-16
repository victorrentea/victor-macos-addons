import AppKit
import Foundation

enum DarkModeToggle {
    private static var _cachedIsDark: Bool = {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }()

    static func toggle() {
        let targetDark = !_cachedIsDark
        let setScript = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(targetDark ? "true" : "false")"
        guard AppleScriptRunner.run(setScript) != nil else {
            overlayError("Failed to set dark mode")
            return
        }
        _cachedIsDark = targetDark
        overlayInfo(targetDark ? "Entered dark mode" : "Exited dark mode")
    }

    static func isDark() -> Bool {
        return _cachedIsDark
    }
}
