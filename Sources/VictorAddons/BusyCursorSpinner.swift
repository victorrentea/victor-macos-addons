import AppKit

/// A small spinner that rides just off the cursor's hip while something slow
/// runs — here, the ~10 s the ⌘⌃V picker spends waiting for whisper to catch up.
///
/// It exists because that wait is otherwise indistinguishable from the shortcut
/// not being bound: the key is pressed, nothing appears, and the natural next
/// move is to press it again. The eye is on the cursor at the moment of a
/// keypress, so that is where the "yes, I heard you" belongs.
///
/// A real busy *cursor* is not available: `NSCursor` only applies while our own
/// window is under the pointer, and this app has no window there — the whole
/// point is that the shortcut fires over somebody else's app. So the spinner is
/// a tiny click-through panel that chases `NSEvent.mouseLocation` instead.
@MainActor
final class BusyCursorSpinner {
    private var panel: NSPanel?
    private var indicator: NSProgressIndicator?
    private var timer: Timer?

    private let side: CGFloat = 20
    /// Below-right of the hotspot, the quadrant a macOS cursor's own artwork
    /// leaves free, so the spinner never covers what is being pointed at.
    private let offset = CGPoint(x: 14, y: -26)

    func show() {
        guard panel == nil else { return }

        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: side, height: side))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        indicator = spinner

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        // Click-through in every sense: a progress indicator that could swallow
        // a click, over an app the user is still working in, would be a bug with
        // no visible cause.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView?.addSubview(spinner)
        self.panel = panel

        follow()
        panel.orderFrontRegardless()

        // 30 ms keeps it visually glued to a moving cursor; the panel is 20 pt
        // of nothing, so the cost is a window move.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        indicator?.stopAnimation(nil)
        indicator = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func follow() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x + offset.x, y: mouse.y + offset.y))
    }
}
