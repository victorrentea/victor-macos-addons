import AppKit

/// The red **−1** that flies from an exploded ☕ to the break watch and takes a
/// minute off the countdown when it lands.
///
/// Why this one drawing stayed in addons while every other pixel left with
/// `EmojiAnimator`: `targetGlobal` is sampled EVERY FRAME. The watch may be
/// zooming in from a coffee that popped on the same tick, or be dragged
/// mid-flight, and the token has to end up wherever it actually is at that
/// moment — a cross-process call cannot re-sample a moving target 60 times a
/// second, and the deduction happens on ARRIVAL, so the number you watch coming
/// in IS the minute rather than a decoration next to one that already happened.
/// The ☕ themselves still live in the effects app; it fires
/// `/effects/event?type=coffee-popped&x=&y=` back here when one explodes.
final class MinuteToken {
    static let shared = MinuteToken()
    private init() {}

    private static let flightSeconds: CFTimeInterval = 1.15

    /// Created on the first flight and taken back down when the last one lands:
    /// a fullscreen panel that exists all day for a token that appears twice a
    /// workshop is a window in every screenshot and every Mission Control.
    private var panel: AddonsOverlayPanel?
    private var inFlight = 0

    /// Fling a **−1** from `point` (global coordinates) to the break timer and,
    /// when it lands, call `onArrival` — which is what actually takes the minute
    /// off the countdown.
    ///
    /// It shrinks to half its size on the way in (near → big, at the clock →
    /// small), so a cluster of coffees popping reads as several minutes
    /// converging on the watch. If the timer is closed mid-flight the token just
    /// fades out and `onArrival` never fires — there is nothing left to subtract
    /// from. Main thread only.
    func fly(fromGlobal point: CGPoint,
             targetGlobal: @escaping () -> CGPoint?,
             onArrival: @escaping () -> Void) {
        guard let hostLayer = hostLayer() else { return }
        let screen = AppDelegate.findRetinaScreen().frame
        let start = CGPoint(x: point.x - screen.origin.x, y: point.y - screen.origin.y)

        let size: CGFloat = 190
        let token = CATextLayer()
        token.string = "−1"
        token.font = NSFont.boldSystemFont(ofSize: 130)
        token.fontSize = 130
        token.alignmentMode = .center
        token.foregroundColor = NSColor.systemRed.cgColor
        token.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        // Black halo: the token crosses whatever is on the desktop on its way to
        // the clock, and red on red text needs an edge to stay readable.
        token.shadowColor = NSColor.black.cgColor
        token.shadowRadius = 6
        token.shadowOpacity = 1
        token.shadowOffset = .zero
        token.masksToBounds = false
        token.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        token.position = start
        hostLayer.addSublayer(token)
        inFlight += 1

        let t0 = CACurrentMediaTime()
        let dur = Self.flightSeconds
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak token] tm in
            guard let token else { tm.invalidate(); return }
            guard let tgGlobal = targetGlobal() else {
                // The clock went away mid-flight — drop the token, subtract nothing.
                tm.invalidate()
                CATransaction.begin()
                CATransaction.setCompletionBlock {
                    token.removeFromSuperlayer()
                    self?.landed()
                }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = token.presentation()?.opacity ?? 1
                fade.toValue = 0
                fade.duration = 0.25
                fade.fillMode = .forwards
                fade.isRemovedOnCompletion = false
                token.add(fade, forKey: "fizzle")
                CATransaction.commit()
                return
            }
            let target = CGPoint(x: tgGlobal.x - screen.origin.x, y: tgGlobal.y - screen.origin.y)
            let raw = min(1.0, (CACurrentMediaTime() - t0) / dur)
            // easeInOut: it leaves the blast gently, covers the distance, then settles.
            let e = CGFloat(raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2)
            let arc = sin(Double(e) * .pi) * 70                  // a hump, so it "floats" over
            CATransaction.begin()
            CATransaction.setDisableActions(true)                // we ARE the animation
            token.position = CGPoint(x: start.x + (target.x - start.x) * e,
                                     y: start.y + (target.y - start.y) * e + CGFloat(arc))
            let s = 1 - 0.5 * e                                  // full size → half at the clock
            token.transform = CATransform3DMakeScale(s, s, 1)
            token.opacity = Float(e > 0.88 ? (1 - (e - 0.88) / 0.12) : 1)
            CATransaction.commit()

            if raw >= 1.0 {
                tm.invalidate()
                token.removeFromSuperlayer()
                self?.landed()
                onArrival()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The panel's layer, creating and showing the panel on first use.
    private func hostLayer() -> CALayer? {
        if panel == nil {
            let fresh = AddonsOverlayPanel(screen: AppDelegate.findRetinaScreen())
            panel = fresh
        }
        panel?.refreshScreenFrame()
        panel?.orderFrontRegardless()
        return panel?.contentView?.layer
    }

    private func landed() {
        inFlight = max(0, inFlight - 1)
        guard inFlight == 0 else { return }
        panel?.orderOut(nil)
        panel = nil
    }
}
