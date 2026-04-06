import AppKit
import Foundation

enum ScreenshotManager {
    private static let screenshotDir = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")

    static func takeScreenshot() {
        // Create dir if needed
        try? FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "screenshot_\(formatter.string(from: Date())).png"
        let filepath = screenshotDir.appendingPathComponent(filename)

        let display = activeDisplayNumber()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-D", String(display), filepath.path]
        try? process.run()
        process.waitUntilExit()

        overlayInfo("Screenshot saved: \(filename) (display \(display))")
    }

    private static func activeDisplayNumber() -> Int {
        // Returns 1-indexed display number for the screen with the menu bar focus
        guard let mainScreen = NSScreen.main else { return 1 }
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            if screen == mainScreen { return index + 1 }
        }
        return 1
    }
}
