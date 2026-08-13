import AppKit
import Foundation

/// ⌃P — one screenshot, two destinations, always both.
///
/// There used to be two shortcuts (⌃P → clipboard, ⌃⇧P → session folder) and
/// remembering which one you needed *before* pressing it is a decision nobody
/// makes correctly mid-workshop: you take the shot to paste it somewhere, and
/// only hours later — writing the summary — discover it was worth keeping. So
/// the capture now always lands on the clipboard **and** in one well-known
/// folder (`/tmp/victor-screenshots`, next to `/tmp/victor-clip-stack`), named
/// `YYYY-MM-DD_HH-mm-ss.jpg` so a skill can find the day's shots by glob and
/// line each one up against the transcript's `[HH:MM]` stamps.
///
/// The file is the capture and the clipboard is a copy of it (not a second
/// `screencapture -c` run): two runs would be two different moments, and the
/// picture you pasted has to be the picture the summary can quote.
///
/// **Why `~/Library/Caches` and not `/tmp`:** these files must be *reclaimable*.
/// Caches is the one folder emptying the Trash, macOS's Storage Management and
/// every cleaner tool actually reach, and the OS may purge it under disk
/// pressure — all of which is welcome here, because anything a summary keeps is
/// copied into the session folder by the skill that keeps it. `/tmp` looked
/// similar and was worse: invisible to Finder *and* to every cleaner.
enum ScreenshotManager {
    /// Well-known, stable, greppable — the summarizer skills glob it by date.
    static let screenshotsDir: URL = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/victor-screenshots")
        }
        return caches.appendingPathComponent("ro.victorrentea.macos-addons/screenshots")
    }()
    static var onScreenshotTaken: (() -> Void)?
    /// The active training-session folder (set on `session_started`, cleared on
    /// `session_ended`). Screenshots no longer go here — `SessionNotesAppender`
    /// still uses it for the notes file.
    static var sessionFolder: URL?

    @discardableResult
    static func takeScreenshot() -> URL? {
        let target = activeDisplay()
        let display = target.number

        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        let filename = Self.filename(for: Date())
        let filepath = screenshotsDir.appendingPathComponent(filename)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", "-t", "jpg", "-D", String(display), filepath.path]
        try? process.run()
        process.waitUntilExit()

        let saved = FileManager.default.fileExists(atPath: filepath.path)
        if saved {
            copyToClipboard(filepath)
            overlayInfo("📸 \(filename) (display \(display)) → clipboard + \(screenshotsDir.path)")
        } else {
            overlayInfo("⚠️ Screenshot failed (display \(display))")
        }

        if let screen = target.screen {
            DispatchQueue.main.async {
                ScreenCaptureFlash.flash(on: screen, showCameraGlyph: true)
            }
        }
        // A folder nobody looks at has to bound itself. Off the capture path —
        // the shot is already on the clipboard, the pruning can take its time.
        DispatchQueue.global(qos: .background).async { prune() }
        onScreenshotTaken?()
        return saved ? filepath : nil
    }

    /// Enforce `ScreenshotRetentionPolicy` over the folder. Best-effort by
    /// design: a file that refuses to delete is not worth a word to anyone.
    static func prune(now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fm.contentsOfDirectory(at: screenshotsDir,
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return }
        let items: [ScreenshotRetentionPolicy.Item] = urls.compactMap { url in
            guard url.pathExtension.lowercased() == "jpg",
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  let date = v.contentModificationDate else { return nil }
            return .init(name: url.lastPathComponent, modified: date, bytes: v.fileSize ?? 0)
        }
        let doomed = ScreenshotRetentionPolicy.toDelete(items, now: now)
        guard !doomed.isEmpty else { return }
        for name in doomed {
            try? fm.removeItem(at: screenshotsDir.appendingPathComponent(name))
        }
        NSLog("[Screenshot] pruned \(doomed.count) old screenshot(s)")
    }

    /// `2026-08-13_14-30-05.jpg` — sortable, and both halves are parseable, so a
    /// skill can select "screenshots taken during this call" by filename alone.
    static func filename(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date) + ".jpg"
    }

    /// PNG *and* TIFF on the pasteboard: the clip-stack poller and most native
    /// apps read TIFF, CLIs (Claude Code, Copilot) read PNG. Decoding happens
    /// outside the gate — only the pasteboard writes belong inside it.
    private static func copyToClipboard(_ file: URL) {
        guard let data = try? Data(contentsOf: file),
              let rep = NSBitmapImageRep(data: data) else { return }
        let png = rep.representation(using: .png, properties: [:])
        let tiff = rep.tiffRepresentation
        PasteboardGate.sync { pb in
            pb.clearContents()
            if let png { pb.setData(png, forType: .png) }
            if let tiff { pb.setData(tiff, forType: .tiff) }
        }
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
