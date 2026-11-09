import AppKit

/// The hint a held watch shows beside itself: "▲ +1 min · wheel · ▼ −1 min".
///
/// Holding the break watch (or the ⏱️ Timer) turns the wheel into ±minutes
/// (`BreakTimerView.startScrollMonitor`), but nothing on screen said so, nor
/// which way is "more" — and with the mouse wheel reversed (`ScrollReversal`)
/// and the trackpad natural, "up" is not something to guess. So a narrow
/// strip appears at the watch's side while the press lasts, the side where
/// Victor drew it (2026-11-09): right of the watch, centred on its height —
/// left of it when the right would leave the screen.
enum BreakTimerScrollHintLayout {
    static let gap: CGFloat = 6

    /// The strip's size for a watch of this height: half its height, within
    /// readable bounds, and narrow (≈ 0.45 of its own height).
    static func size(forWatchHeight h: CGFloat) -> CGSize {
        let height = min(max(h * 0.5, 84), 150)
        return CGSize(width: (height * 0.45).rounded(), height: height.rounded())
    }

    /// Right of the watch, vertically centred; flipped to the left when it
    /// would cross `visible.maxX`; kept inside `visible` vertically.
    static func frame(watch: CGRect, visible: CGRect) -> CGRect {
        let s = size(forWatchHeight: watch.height)
        var x = watch.maxX + gap
        if x + s.width > visible.maxX { x = watch.minX - gap - s.width }
        var y = watch.midY - s.height / 2
        y = min(max(y, visible.minY), visible.maxY - s.height)
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }
}

/// The borderless, click-through panel that draws the hint. A child of the
/// watch's panel, so a drag carries it along for free; a resize re-places it.
final class BreakTimerScrollHint {
    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    /// Shown only after the press has lasted this long, so a click on the
    /// watch never flashes it.
    static let delay: TimeInterval = 0.3

    var isShowing: Bool { panel?.isVisible == true }

    func schedule(beside window: NSWindow, color: NSColor) {
        cancel()
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.show(beside: window, color: color)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func show(beside window: NSWindow, color: NSColor) {
        let p = panel ?? makePanel()
        panel = p
        (p.contentView as? HintView)?.color = color
        p.contentView?.needsDisplay = true
        place(beside: window)
        if p.parent !== window { p.parent?.removeChildWindow(p); window.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    /// Re-place after the watch changed size (a drag moves the child by itself).
    func follow(_ window: NSWindow) {
        guard isShowing else { return }
        place(beside: window)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
    }

    private func place(beside window: NSWindow) {
        guard let p = panel else { return }
        let visible = (window.screen ?? NSScreen.main)?.frame ?? window.frame.insetBy(dx: -1000, dy: -1000)
        p.setFrame(BreakTimerScrollHintLayout.frame(watch: window.frame, visible: visible), display: true)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.contentView = HintView()
        return p
    }

    private final class HintView: NSView {
        var color: NSColor = .systemRed

        override func draw(_ dirtyRect: NSRect) {
            let b = bounds
            let r = min(b.width, b.height) * 0.28
            let bg = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: r, yRadius: r)
            NSColor(calibratedWhite: 0, alpha: 0.88).setFill()
            bg.fill()
            color.setStroke()
            bg.lineWidth = 1.5
            bg.stroke()

            let w = b.width
            let big = NSFont.systemFont(ofSize: w * 0.40, weight: .heavy)
            let small = NSFont.systemFont(ofSize: w * 0.24, weight: .semibold)
            func line(_ s: String, _ font: NSFont, centreY: CGFloat, alpha: CGFloat = 1) {
                let style = NSMutableParagraphStyle(); style.alignment = .center
                let a = NSAttributedString(string: s, attributes: [
                    .font: font, .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: style])
                let h = a.size().height
                a.draw(in: NSRect(x: 0, y: centreY - h / 2, width: w, height: h))
            }
            let h = b.height
            line("▲", small, centreY: h * 0.87)
            line("+1", big, centreY: h * 0.73)
            line("min", small, centreY: h * 0.50, alpha: 0.75)
            line("−1", big, centreY: h * 0.27)
            line("▼", small, centreY: h * 0.13)
        }
    }
}
