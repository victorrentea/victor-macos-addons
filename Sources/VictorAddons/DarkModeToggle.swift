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

    /// The live system appearance, for the menu's checkbox. `isDark()` above is
    /// a cache of the flips THIS process made — enough to decide what the next
    /// ⌘⌃⌥D should do, wrong for a tick that has to be right every time the
    /// menu opens, since System Settings flips the same switch. Main thread
    /// only (`NSApp`), which is where the menu is built and refreshed.
    static func isDarkNow() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
