import AppKit
import QuartzCore

/// 🔍/🔎 What the `ZoomEngine` flip looks like: **ShareZoom's zigzag frame, sharpening
/// or flattening** on the screen under the pointer (Victor, 2026-11-02: *"acele
/// triunghiuri să apară prin adâncirea marginilor la trecerea pe sintetic, respectiv să
/// se aplatizeze până la dispariție când trec în modul macOS nativ. Iar lupa … să fie
/// eliminată: mă voi orienta după marginile care se ascut / aplatizează"*).
///
/// - → `share`: a flat black band fades in along the edge, its teeth grow
///   (`ZigzagFrame.appear`), it holds for a beat, and the whole frame fades.
/// - → `system`: the frame is there sharp, its teeth sink back into the edge, and the
///   straight band fades (`ZigzagFrame.disappear`). ShareZoom plays the same thing on
///   its own when a zoom ends (`flattenAway`).
///
/// Until that day: a drawn magnifier at the cursor that exploded into shards or
/// dissolved in (2026-10-26). One borderless, click-through panel per play, at
/// ShareZoom's level, ordered out when the animation is over. Main thread only.
final class ZoomSwitchEffect {
    private var panel: NSPanel?
    private var cleanup: DispatchWorkItem?

    static let hold: CFTimeInterval = 0.6
    static let fade: CFTimeInterval = 0.25

    func play(_ engine: ZoomEngine, at point: CGPoint) {
        guard let screen = NSScreen.physical.first(where: { NSMouseInRect(point, $0.frame, false) })
                ?? NSScreen.main else { return }
        play(engine, on: screen)
    }

    /// The flattening alone, on `screen` — a ShareZoom that just went back to 1×.
    func flattenAway(on screen: NSScreen) { play(.system, on: screen) }

    private func play(_ engine: ZoomEngine, on screen: NSScreen) {
        stop()
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = ShareZoom.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view
        guard let root = view.layer else { return }
        root.contentsScale = screen.backingScaleFactor

        let edge = CAShapeLayer()
        edge.frame = view.bounds
        edge.fillRule = .evenOdd
        edge.fillColor = NSColor.black.cgColor
        let line = CAShapeLayer()
        line.frame = view.bounds
        line.fillColor = nil
        line.strokeColor = NSColor(calibratedWhite: 1, alpha: 0.55).cgColor
        line.lineWidth = 1.5
        line.lineJoin = .miter
        root.addSublayer(edge)
        root.addSublayer(line)

        let total: CFTimeInterval
        if engine == .share {
            let shown = ZigzagFrame.appear(edge: edge, line: line)
            let start = CACurrentMediaTime() + shown + Self.hold
            for layer in [edge, line] {
                let out = CABasicAnimation(keyPath: "opacity")
                out.fromValue = 1
                out.toValue = 0
                out.beginTime = start
                out.duration = Self.fade
                out.fillMode = .forwards
                out.isRemovedOnCompletion = false
                layer.add(out, forKey: "fadeOut")
            }
            total = shown + Self.hold + Self.fade
        } else {
            total = ZigzagFrame.disappear(edge: edge, line: line)
        }
        self.panel = panel
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.stop() }
        cleanup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.05, execute: work)
    }

    private func stop() {
        cleanup?.cancel()
        cleanup = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
