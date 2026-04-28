import AppKit
import Foundation

enum ScreenshotManager {
    private static let defaultScreenshotDir = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")
    static var onScreenshotTaken: (() -> Void)?
    /// When set, screenshots are saved here (active training-session folder). Cleared on session_ended.
    static var sessionFolder: URL?

    static func takeScreenshot() {
        let targetDir = sessionFolder ?? defaultScreenshotDir
        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH-mm-ss"
        let filename = "\(dateFormatter.string(from: date))-screen-\(timeFormatter.string(from: date)).jpg"
        let filepath = targetDir.appendingPathComponent(filename)

        let display = activeDisplayNumber()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "jpg", "-D", String(display), filepath.path]
        try? process.run()
        process.waitUntilExit()

        overlayInfo("Screenshot saved: \(filename) (display \(display))")
        onScreenshotTaken?()
    }

    private static func activeDisplayNumber() -> Int {
        // Returns 1-indexed display number for the screen with the frontmost window
        // Get the frontmost window's screen
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 1
        }

        // Find the frontmost window
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontmostApp.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"] else {
                continue
            }

            // Find which screen contains this window
            let screens = NSScreen.screens
            for (index, screen) in screens.enumerated() {
                let frame = screen.frame
                if x >= frame.minX && x < frame.maxX && y >= frame.minY && y < frame.maxY {
                    return index + 1
                }
            }
        }

        // Fallback to main screen
        guard let mainScreen = NSScreen.main else { return 1 }
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            if screen == mainScreen { return index + 1 }
        }
        return 1
    }
}
