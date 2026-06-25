import Cocoa

/// Full-width countdown progress bar pinned to the bottom of the screen.
///
/// Triggered from the tablet (3s/5s/7s/10s buttons): a semi-transparent yellow
/// bar grows from the left edge to the full screen width over `seconds`, acting
/// as a discreet warm-up / break timer. When the fill completes the bar fades
/// out so the screen clears. Pressing another value restarts it from zero
/// (latest-wins). Lives on the built-in Retina display alongside the emoji effects.
///
/// Rendered as a CALayer on the overlay's host layer — the same layer the emoji
/// effects use — NOT as an NSView subview. Adding a subview onto that
/// manually-populated, layer-backed host view does not composite (the bar never
/// appeared); a CALayer in the same tree renders reliably.
final class ProgressBarOverlay {
    private let hostLayer: CALayer
    private var bar: CALayer?
    private var fadeWork: DispatchWorkItem?

    /// Fired when the bar fills all the way to the right edge — i.e. the
    /// interval elapsed naturally. NOT fired on `cancel()` (manual stop or a
    /// restart-from-zero), since that cancels the pending work item.
    var onComplete: (() -> Void)?

    private static let height: CGFloat = 100           // thick, clearly visible
    private static let alpha: Float = 0.5              // translucent — discreet
    private static let fadeDuration: TimeInterval = 0.5

    init(hostLayer: CALayer) {
        self.hostLayer = hostLayer
    }

    /// Start (or restart) the bar, filling left→right over `seconds`.
    func start(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        cancel()  // restart-from-zero semantics

        let width = hostLayer.bounds.width > 0
            ? hostLayer.bounds.width
            : (NSScreen.main?.frame.width ?? 1440)

        // anchorPoint at the bottom-left so growing the width fills left→right and
        // position (0,0) pins it to the bottom-left of the host layer (which is
        // non-flipped: origin bottom-left, same as the confetti's "y=0 = bottom").
        let fill = CALayer()
        fill.anchorPoint = CGPoint(x: 0, y: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)          // no implicit bounds animation
        fill.position = CGPoint(x: 0, y: 0)
        fill.bounds = CGRect(x: 0, y: 0, width: width, height: Self.height)
        fill.backgroundColor = NSColor.systemYellow.cgColor
        fill.opacity = Self.alpha
        hostLayer.addSublayer(fill)
        CATransaction.commit()
        bar = fill

        // The model is already full width; the explicit animation drives the
        // presentation from 0 → full over `seconds`, then holds (no flicker).
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0
        grow.toValue = width
        grow.duration = seconds
        grow.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(grow, forKey: "fill")

        // After the fill completes, celebrate at the right corner, then fade
        // the bar out so the screen clears.
        let work = DispatchWorkItem { [weak self] in
            self?.onComplete?()
            self?.fadeOut()
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        overlayInfo("Progress bar started: \(Int(seconds))s")
    }

    /// Remove the bar immediately (no fade).
    func cancel() {
        fadeWork?.cancel()
        fadeWork = nil
        bar?.removeFromSuperlayer()
        bar = nil
    }

    private func fadeOut() {
        guard let bar = bar else { return }
        self.bar = nil
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = bar.opacity
        fade.toValue = 0
        fade.duration = Self.fadeDuration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        bar.add(fade, forKey: "fadeOut")
        bar.opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) { [weak bar] in
            bar?.removeFromSuperlayer()
        }
    }
}
