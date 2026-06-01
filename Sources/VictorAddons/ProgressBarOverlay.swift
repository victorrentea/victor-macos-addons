import Cocoa

/// Full-width countdown progress bar pinned to the bottom of the screen.
///
/// Triggered from the tablet (3S/5S/7S/10S buttons): a gray bar grows from the
/// left edge to the full screen width over `seconds`, acting as a visible
/// warm-up / break timer. When the fill completes the bar fades out so the
/// screen clears. Pressing another value restarts it from zero (latest-wins).
///
/// Draws directly into the main overlay panel's host layer, so it lives on the
/// built-in Retina display alongside the emoji effects.
final class ProgressBarOverlay {
    private let hostLayer: CALayer
    private var barLayer: CALayer?
    private var fadeWork: DispatchWorkItem?

    private static let height: CGFloat = 30
    private static let fillColor = NSColor(white: 0.5, alpha: 0.9)
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

        // anchorPoint (0,0) + position (0,0) pins the bottom-left corner to the
        // bottom-left of the screen; growing bounds.width then extends rightward.
        let bar = CALayer()
        bar.anchorPoint = CGPoint(x: 0, y: 0)
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.height)
        bar.position = CGPoint(x: 0, y: 0)
        bar.backgroundColor = Self.fillColor.cgColor
        hostLayer.addSublayer(bar)
        barLayer = bar

        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0
        grow.toValue = width
        grow.duration = seconds
        grow.timingFunction = CAMediaTimingFunction(name: .linear)
        grow.isRemovedOnCompletion = false
        grow.fillMode = .forwards
        bar.add(grow, forKey: "grow")

        // After the fill completes, fade the bar out so the screen clears.
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        overlayInfo("Progress bar started: \(Int(seconds))s")
    }

    /// Remove the bar immediately (no fade).
    func cancel() {
        fadeWork?.cancel()
        fadeWork = nil
        barLayer?.removeFromSuperlayer()
        barLayer = nil
    }

    private func fadeOut() {
        guard let bar = barLayer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        bar.add(fade, forKey: "fade")
        let remove = DispatchWorkItem { [weak self] in
            self?.barLayer?.removeFromSuperlayer()
            self?.barLayer = nil
        }
        fadeWork = remove
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration, execute: remove)
    }
}
