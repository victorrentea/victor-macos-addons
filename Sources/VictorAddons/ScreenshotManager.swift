import AppKit
import Foundation

enum ScreenshotManager {
    private static let screenshotDir = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")

    static func takeScreenshot() {
        // Create dir if needed
        try? FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let filename = "\(formatter.string(from: Date()))-screen.jpg"
        let filepath = screenshotDir.appendingPathComponent(filename)

        let display = activeDisplayNumber()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "jpg", "-D", String(display), filepath.path]
        try? process.run()
        process.waitUntilExit()

        overlayInfo("Screenshot saved: \(filename) (display \(display))")
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
