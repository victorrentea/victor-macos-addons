import AppKit
import Foundation

enum ScreenshotManager {
    private static let defaultScreenshotDir = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")
    static var onScreenshotTaken: (() -> Void)?
    /// When set, screenshots are saved here (active training-session folder). Cleared on session_ended.
    static var sessionFolder: URL?

    static func takeScreenshot(toClipboard: Bool = false) {
        let target = activeDisplay()
        let display = target.number
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

        if toClipboard {
            process.arguments = ["-c", "-x", "-C", "-t", "jpg", "-D", String(display)]
            try? process.run()
            process.waitUntilExit()
            overlayInfo("Screenshot copied to clipboard (display \(display))")
        } else {
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

            process.arguments = ["-x", "-C", "-t", "jpg", "-D", String(display), filepath.path]
            try? process.run()
            process.waitUntilExit()
            overlayInfo("Screenshot saved: \(filename) (display \(display))")
        }
        if let screen = target.screen {
            DispatchQueue.main.async {
                ScreenCaptureFlash.flash(on: screen)
            }
        }
        onScreenshotTaken?()
    }

    /// Returns the 1-indexed display number (as expected by `screencapture -D`) and the
    /// matching NSScreen for the screen currently containing the mouse cursor.
    /// Falls back to display 1 (main display). Uses mouse position rather than focused-window
    /// position so the captured frame always contains the cursor that `-C` will draw.
    private static func activeDisplay() -> (number: Int, screen: NSScreen?) {
        let mouse = NSEvent.mouseLocation  // Cocoa coords: bottom-left origin
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            return (1, NSScreen.main)
        }

        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return (1, screen) }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return (1, screen) }
        if let idx = displays.firstIndex(of: displayID) {
            return (idx + 1, screen)
        }
        return (1, screen)
    }
}
