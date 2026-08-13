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
        // Read the cursor BEFORE the shutter: it is what `-C` draws into the
        // picture, and it is the one thing about the shot the picture itself
        // cannot tell you afterwards.
        let cursor = CGEvent(source: nil)?.location

        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        let filepath = uniqueURL(for: Date(), cursor: cursor)
        let filename = filepath.lastPathComponent

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-C", "-t", "jpg", "-D", String(display), filepath.path]
        try? process.run()
        process.waitUntilExit()

        let saved = FileManager.default.fileExists(atPath: filepath.path)

        // The border flash goes up the instant the pixels are safe — BEFORE the
        // clipboard work, not after it. Re-encoding a retina capture to PNG *and*
        // TIFF is by far the most expensive step here (hundreds of ms), and doing
        // it first pushed the yellow border that far behind the keypress, which
        // read as "⌃P is laggy". The flash cannot go any earlier than this:
        // it is a window on screen, so anything drawn before the capture is drawn
        // *into* the capture.
        if saved, let screen = target.screen {
            DispatchQueue.main.async {
                ScreenCaptureFlash.flash(on: screen, showCameraGlyph: true)
                if let cursor, let primaryMaxY = NSScreen.screens.first?.frame.maxY {
                    ScreenCaptureFlash.markCursor(at: CGPoint(x: cursor.x, y: primaryMaxY - cursor.y))
                }
            }
        }

        if saved {
            copyToClipboard(filepath)
            overlayInfo("📸 \(filename) (display \(display)) → clipboard + \(screenshotsDir.path)")
        } else {
            overlayInfo("⚠️ Screenshot failed (display \(display))")
        }

        // A folder nobody looks at has to bound itself. Off the capture path —
        // the shot is already on the clipboard, the pruning can take its time.
        DispatchQueue.global(qos: .background).async { prune() }
        onScreenshotTaken?()
        return saved ? filepath : nil
    }

    /// Hold ⌃P (or the menu item) → macOS's own crosshair selection, then the
    /// same two destinations as a plain ⌃P: clipboard **and** a dated file.
    ///
    /// `screencapture -i` is the very tool ⌃⇧P used to reach, minus the choice:
    /// you no longer decide "full or crop" before pressing, you decide it by how
    /// long you keep the key down. Esc / right-click cancels the selection and
    /// writes no file — which must leave the clipboard alone, so nothing here
    /// runs unless a file actually appeared.
    @discardableResult
    static func takeCropScreenshot() -> URL? {
        // Our own border must stay off the screen for the whole selection: one
        // still fading from an earlier shot would be dragged into the crop, and
        // any raised over the crosshair puts a window above screencapture's own
        // selection overlay — observed to end with the selection cancelled and
        // no file written.
        ScreenCaptureFlash.beginSuppression()
        defer { ScreenCaptureFlash.endSuppression() }

        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        let filepath = uniqueURL(for: Date())
        let filename = filepath.lastPathComponent

        // Watched so the confirmation border can frame the crop; `screencapture`
        // itself says nothing about the region it took.
        let drag = CropDragTracker()
        drag.start()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-t", "jpg", filepath.path]
        try? process.run()
        process.waitUntilExit()
        let draggedRect = drag.stop()

        guard FileManager.default.fileExists(atPath: filepath.path) else {
            overlayInfo("📸 crop cancelled")
            return nil   // Esc: clipboard and folder untouched.
        }

        flashCropBorder(around: draggedRect, capture: filepath)
        copyToClipboard(filepath)
        overlayInfo("✂️ \(filename) → clipboard + \(screenshotsDir.path)")

        DispatchQueue.global(qos: .background).async { prune() }
        onScreenshotTaken?()
        return filepath
    }

    /// Frame the crop that was just taken — or show nothing at all.
    ///
    /// The whole-screen border belongs to the whole-screen shot: after a
    /// selection it claims the wrong thing, since not taking the whole screen is
    /// exactly what the crop was for. So the border goes around the region — and
    /// only when the drag we watched agrees with the saved picture's own pixel
    /// dimensions. A window pick, or a drag that couldn't be reconstructed,
    /// draws nothing: silence is right, a border in the wrong place isn't.
    private static func flashCropBorder(around dragged: CGRect?, capture: URL) {
        guard let dragged else { return }
        DispatchQueue.main.async {
            guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return }
            let cocoa = CropFlashGeometry.cocoaRect(dragged, primaryMaxY: primaryMaxY)
            let scale = NSScreen.screens.first { NSMouseInRect(CGPoint(x: cocoa.midX, y: cocoa.midY), $0.frame, false) }?
                .backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            guard let pixels = imagePixelSize(capture),
                  CropFlashGeometry.matchesCapture(drag: dragged, imagePixels: pixels, scale: scale) else { return }
            ScreenCaptureFlash.flash(around: cocoa)
        }
    }

    /// The capture's dimensions in pixels, read from the file's metadata alone
    /// (no decode — this runs while the user is waiting to paste).
    private static func imagePixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
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

    /// A free path for a capture taken *now*. The name is a timestamp to the
    /// second, and two captures can land inside one second — which is not an
    /// abstract worry: a held ⌃P takes the full screen and then names the crop
    /// moments later, and when both names collided the crop overwrote the full
    /// shot and the supersede that followed deleted the only remaining file.
    /// Later shots take a `-2` suffix, leaving the timestamp prefix (which the
    /// summarizer skills parse) untouched.
    static func uniqueURL(for date: Date, cursor: CGPoint? = nil, in dir: URL? = nil) -> URL {
        let dir = dir ?? screenshotsDir
        let base = filename(for: date, cursor: cursor)
        let stem = String(base.dropLast(4))   // without ".jpg"
        var url = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(n).jpg")
            n += 1
        }
        return url
    }

    /// `2026-08-13_14-30-05.jpg` — sortable, and both halves are parseable, so a
    /// skill can select "screenshots taken during this call" by filename alone.
    ///
    /// With a `cursor` it becomes `2026-08-13_14-30-05_at1234x567.jpg`: global
    /// CG coordinates (y down from the primary's top, so negatives are normal on
    /// a screen left of it), rounded to whole points. The picture shows the
    /// pointer but nothing in it says *which display coordinate* that was, and a
    /// summary reading the folder months later cannot recover it — the filename
    /// is the only place it survives. `screenshot_index.py` in the
    /// training-summarizer skill matches the timestamp prefix and ignores this.
    static func filename(for date: Date, cursor: CGPoint? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = f.string(from: date)
        guard let cursor else { return stamp + ".jpg" }
        return "\(stamp)_at\(Int(cursor.x.rounded()))x\(Int(cursor.y.rounded())).jpg"
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
