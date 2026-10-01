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
///
/// The theme alone is half the fix: `~/.claude/hooks/session-color.sh` paints
/// every Claude tab in Terminal a fixed tint, and the light palette on the dark
/// tint was just as unreadable as the reverse. So each sync also asks that hook
/// to repaint the tinted tabs into the tint of the new appearance.
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

    static var tabPainter: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks/session-color.sh")
    }

    static func sync() {
        let isDark = DarkModeToggle.isDarkNow()
        repaintTabs(isDark: isDark)
        let wanted = contents(isDark: isDark)
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

    /// Not gated on the theme file changing: at launch the file can already be
    /// right while tabs born under the other appearance are still wrong.
    /// Fire-and-forget — it is an AppleScript round trip over every tab.
    static func repaintTabs(isDark: Bool) {
        guard FileManager.default.isExecutableFile(atPath: tabPainter.path) else { return }
        let p = Process()
        p.executableURL = tabPainter
        p.arguments = ["follow", isDark ? "dark" : "light"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
