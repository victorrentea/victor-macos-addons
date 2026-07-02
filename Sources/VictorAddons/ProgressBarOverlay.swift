import Cocoa

/// Full-width countdown progress bar pinned to the bottom of the screen.
///
/// Triggered from the tablet (3s/5s/7s/10s buttons): a semi-transparent yellow
/// bar grows from the left edge to the full screen width over `seconds`, acting
/// as a discreet warm-up / break timer. When the fill completes the bar fades
/// out so the screen clears. Pressing another value restarts it from zero
/// (latest-wins). Lives on the built-in Retina display alongside the emoji effects.
///
/// A small black countdown number sits immediately to the LEFT of the bar,
/// counting the remaining whole seconds (N…1) in sync with the fill, then
/// disappears with the bar on completion / cancel.
///
/// Rendered as a CALayer on the overlay's host layer — the same layer the emoji
/// effects use — NOT as an NSView subview. Adding a subview onto that
/// manually-populated, layer-backed host view does not composite (the bar never
/// appeared); a CALayer in the same tree renders reliably.
final class ProgressBarOverlay {
    private let hostLayer: CALayer
    private var bar: CALayer?
    private var fadeWork: DispatchWorkItem?

    // Countdown number shown to the left of the bar.
    private var countdownLabel: CATextLayer?
    private var countdownTimer: Timer?
    private var countdownDeadline: Date?

    /// Fired when the bar fills all the way to the right edge — i.e. the
    /// interval elapsed naturally. NOT fired on `cancel()` (manual stop or a
    /// restart-from-zero), since that cancels the pending work item.
    var onComplete: (() -> Void)?

    private static let height: CGFloat = 100           // thick, clearly visible
    private static let alpha: Float = 0.5              // translucent — discreet
    private static let fadeDuration: TimeInterval = 0.5

    // Left gutter reserved for the countdown number, so the bar starts to its
    // right and never overlaps it. `numberGap` is the breathing room between the
    // number's right edge and the bar's left edge.
    private static let numberAreaWidth: CGFloat = 160
    private static let numberGap: CGFloat = 20
    private static let numberFontSize: CGFloat = 80

    init(hostLayer: CALayer) {
        self.hostLayer = hostLayer
    }

    /// Start (or restart) the bar, filling left→right over `seconds`.
    func start(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        cancel()  // restart-from-zero semantics

        let screenWidth = hostLayer.bounds.width > 0
            ? hostLayer.bounds.width
            : (NSScreen.main?.frame.width ?? 1440)
        // The bar occupies everything to the right of the number gutter.
        let barOriginX = Self.numberAreaWidth
        let width = max(1, screenWidth - barOriginX)

        // anchorPoint at the bottom-left so growing the width fills left→right and
        // position (barOriginX,0) pins it to the bottom-left of the bar region on the
        // host layer (which is non-flipped: origin bottom-left, same as the confetti's
        // "y=0 = bottom").
        let fill = CALayer()
        fill.anchorPoint = CGPoint(x: 0, y: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)          // no implicit bounds animation
        fill.position = CGPoint(x: barOriginX, y: 0)
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

        // Black countdown number, right-aligned in the gutter so it hugs the bar's
        // left edge. Vertically centred within the bar's height band.
        let lineHeight = Self.numberFontSize * 1.2
        let label = CATextLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.anchorPoint = CGPoint(x: 0, y: 0)
        label.frame = CGRect(x: 0,
                             y: (Self.height - lineHeight) / 2,
                             width: Self.numberAreaWidth - Self.numberGap,
                             height: lineHeight)
        label.alignmentMode = .right
        label.foregroundColor = NSColor.black.cgColor
        label.font = NSFont.boldSystemFont(ofSize: Self.numberFontSize)
        label.fontSize = Self.numberFontSize
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2   // crisp on Retina
        hostLayer.addSublayer(label)
        CATransaction.commit()
        countdownLabel = label

        // Drive the number off a deadline so restarts / drift can't desync it from
        // the bar. `ceil(remaining)` yields N…1 through the interval, 0 at the end.
        countdownDeadline = Date().addingTimeInterval(seconds)
        updateCountdown()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer

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

    /// Refresh the countdown number from the deadline; hide it once time's up.
    private func updateCountdown() {
        guard let deadline = countdownDeadline, let label = countdownLabel else { return }
        let remaining = deadline.timeIntervalSinceNow
        CATransaction.begin()
        CATransaction.setDisableActions(true)          // no implicit contents crossfade
        if remaining <= 0 {
            label.isHidden = true
            countdownTimer?.invalidate()
            countdownTimer = nil
        } else {
            label.string = "\(Int(ceil(remaining)))"
        }
        CATransaction.commit()
    }

    /// Remove the bar (and countdown number) immediately (no fade).
    func cancel() {
        fadeWork?.cancel()
        fadeWork = nil
        tearDownCountdown()
        bar?.removeFromSuperlayer()
        bar = nil
    }

    /// Stop and remove the countdown number + its timer.
    private func tearDownCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDeadline = nil
        countdownLabel?.removeFromSuperlayer()
        countdownLabel = nil
    }

    private func fadeOut() {
        guard let bar = bar else { return }
        self.bar = nil

        // Fade the countdown number out alongside the bar (stop its timer first so
        // it can't fight the fade), then remove it.
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownDeadline = nil
        let label = countdownLabel
        countdownLabel = nil

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = bar.opacity
        fade.toValue = 0
        fade.duration = Self.fadeDuration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        bar.add(fade, forKey: "fadeOut")
        bar.opacity = 0

        if let label = label {
            let labelFade = CABasicAnimation(keyPath: "opacity")
            labelFade.fromValue = label.opacity
            labelFade.toValue = 0
            labelFade.duration = Self.fadeDuration
            labelFade.fillMode = .forwards
            labelFade.isRemovedOnCompletion = false
            label.add(labelFade, forKey: "fadeOut")
            label.opacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration) { [weak bar, weak label] in
            bar?.removeFromSuperlayer()
            label?.removeFromSuperlayer()
        }
    }
}
