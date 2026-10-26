import AppKit
import CoreGraphics

/// Pure half of "is Zoom sharing my screen right now?", read off the names of
/// Zoom's on-screen windows.
///
/// A share is the only time Zoom puts the `Annotation - Zoom` window up — the
/// transparent layer that covers exactly the shared display (`ZoomSharePrep`
/// uses it as "which screen actually went out"). The share toolbar windows are
/// accepted too, so a share started without annotation still counts. All three
/// were read off a live share on 2026-10-01 (Zoom Workplace 6.6):
/// `zoom share toolbar window`, `zoom share statusbar window`, `Annotation - Zoom`.
enum ZoomShareWindows {
    static let bundleId = "us.zoom.xos"

    static func isSharing(windowNames: [String]) -> Bool {
        windowNames.contains { name in
            let n = name.lowercased()
            return n == "annotation - zoom" || n.contains("share toolbar") || n.contains("share statusbar")
        }
    }

    /// The names of Zoom's on-screen windows, matched by pid: the window list
    /// reports the owner as "Zoom", not the process name `zoom.us`. Window titles
    /// of other apps need Screen Recording, which this app holds for `ShareZoom`.
    static func onScreenNames(pid: pid_t) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == pid else { return nil }
            return w[kCGWindowName as String] as? String
        }
    }
}

/// ⚠️ ⌥+scroll during a Zoom share — the hint that the wrong zoom is in hand.
///
/// With `ZoomEngine.system`, ⌥+scroll is the macOS full-screen magnifier, applied
/// at scanout: Victor sees it, the share never does (`ZoomLensMode`). The one a
/// share carries is ours (`ShareZoom`), one ⌥⇧ tap away; the hint sits by the
/// cursor because that is where the eye is while the wheel turns. The scroll
/// itself is left alone — the local zoom still happens, the hint only says the
/// room is not seeing it. The same pill announces an engine flip (`announce`).
/// Main thread only.
final class ShareZoomHint {
    private var panel: NSPanel?
    private var followTimer: Timer?
    private var hideTimer: Timer?
    /// The window list costs a few ms and a notch emits several scroll events,
    /// so the answer is reused for a second.
    private var sharingCache: (at: CFTimeInterval, sharing: Bool)?

    private let text = "⚠️ Tap ⌥⇧ for Zoom"
    private static let warningColor = NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.0, alpha: 0.95)
    /// Below-right of the hotspot, the quadrant the cursor's own artwork leaves free.
    private let offset = CGPoint(x: 16, y: -34)
    private let visibleFor: TimeInterval = 2.5

    /// Called on main for every ⌥+scroll (⌥ alone, no ⇧/⌘/⌃).
    func optionScrolled() {
        guard isZoomSharing() else { return }
        if panel == nil {
            overlayInfo("⚠️ ⌥+scroll during a Zoom share → hint ⌥⇧")
            show(text, color: Self.warningColor)
        }
        hideAfter(visibleFor)
    }

    /// 🔍/🔎 The `ZoomEngine` just flipped: say which one ⌥+scroll drives now.
    func announce(_ engine: ZoomEngine) {
        hide()
        let color = engine == .share
            ? NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.85, alpha: 0.95)
            : NSColor(calibratedWhite: 0.25, alpha: 0.95)
        show(engine.announcement, color: color)
        hideAfter(1.2)
    }

    private func hideAfter(_ seconds: TimeInterval) {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    func isZoomSharing() -> Bool {
        let now = CACurrentMediaTime()
        if let cache = sharingCache, now - cache.at < 1 { return cache.sharing }
        let zoom = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == ZoomShareWindows.bundleId }
        let sharing = zoom.map { ZoomShareWindows.isSharing(windowNames: ZoomShareWindows.onScreenNames(pid: $0.processIdentifier)) } ?? false
        sharingCache = (now, sharing)
        return sharing
    }

    private func show(_ text: String, color: NSColor) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let pad = CGSize(width: 12, height: 6)
        let size = CGSize(width: label.frame.width + 2 * pad.width, height: label.frame.height + 2 * pad.height)
        label.frame.origin = CGPoint(x: pad.width, y: pad.height)

        let bubble = NSView(frame: NSRect(origin: .zero, size: size))
        bubble.wantsLayer = true
        // Fixed colours, not semantic ones: the bubble is drawn over whatever
        // app is under the cursor, in either appearance, and must read on both.
        bubble.layer?.backgroundColor = color.cgColor
        bubble.layer?.cornerRadius = size.height / 2
        bubble.addSubview(label)

        let panel = NSPanel(contentRect: bubble.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = bubble
        self.panel = panel
        follow()
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.follow()
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func hide() {
        followTimer?.invalidate(); followTimer = nil
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func follow() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x + offset.x, y: mouse.y + offset.y - panel.frame.height / 2))
    }
}
