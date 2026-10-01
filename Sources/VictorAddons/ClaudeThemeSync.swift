import AppKit
import Foundation

/// Keeps every running Claude Code session on the theme that matches the macOS
/// appearance, so ⌘⌃⌥D (or System Settings) re-colours them on the spot.
///
/// Claude Code's `auto` theme asks the terminal for its background (OSC 11)
/// **once, at startup**, and afterwards only re-asks when the terminal pushes a
/// theme change — which Terminal.app never does. So a session started in dark
/// mode kept the dark palette after a flip to light: its recap and every other
/// dim line stayed `rgb(153,153,153)` italic on a white page, barely readable.
///
/// What Claude Code *does* watch live is `~/.claude/themes/*.json`: a custom
/// theme's `base` is re-read on every change of that folder, and every session
/// re-renders with it (measured on 2.1.286: under a second). So the global
/// `theme` setting points at `custom:follow-macos`, and this writes that file's
/// `base` as `dark` or `light` at launch and on each appearance change.
enum ClaudeThemeSync {
    static let slug = "follow-macos"

    static var themeFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/themes/\(slug).json")
    }

    /// The whole file: no overrides — the stock light/dark palettes are fine
    /// on their own background, the problem was only ever the wrong one.
    static func contents(isDark: Bool) -> String {
        "{\"name\": \"Follow macOS\", \"base\": \"\(isDark ? "dark" : "light")\", \"overrides\": {}}\n"
    }

    static func start() {
        sync()
        // Same notification and delay as the menu-bar glyph and the clipboard
        // bezel: it lands slightly before `effectiveAppearance` updates.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { sync() }
        }
    }

    static func sync() {
        let wanted = contents(isDark: DarkModeToggle.isDarkNow())
        // Skip identical writes: each one makes every session reload its themes.
        if (try? String(contentsOf: themeFile, encoding: .utf8)) == wanted { return }
        do {
            try FileManager.default.createDirectory(
                at: themeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wanted.write(to: themeFile, atomically: true, encoding: .utf8)
        } catch {
            overlayError("Claude theme sync failed: \(error.localizedDescription)")
        }
    }
}
