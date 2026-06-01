import Cocoa

/// Full-width countdown progress bar pinned to the bottom of the screen.
///
/// Triggered from the tablet (3S/5S/7S/10S buttons): a translucent frosted-glass
/// bar grows from the left edge to the full screen width over `seconds`, acting
/// as a discreet, barely-visible warm-up / break timer. When the fill completes
/// the bar fades out so the screen clears. Pressing another value restarts it
/// from zero (latest-wins).
///
/// Uses an `NSVisualEffectView` with `.behindWindow` blending so it blurs the
/// content behind the transparent overlay — a genuine glass effect rather than
/// a flat tint. Lives on the built-in Retina display alongside the emoji effects.
final class ProgressBarOverlay {
    private let hostView: NSView
    private var bar: NSVisualEffectView?
    private var fadeWork: DispatchWorkItem?

    private static let height: CGFloat = 15
    private static let alpha: CGFloat = 0.5            // extra translucency — "less visible"
    private static let fadeDuration: TimeInterval = 0.5

    init(hostView: NSView) {
        self.hostView = hostView
    }

    /// Start (or restart) the bar, filling left→right over `seconds`.
    func start(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        cancel()  // restart-from-zero semantics

        let width = hostView.bounds.width > 0
            ? hostView.bounds.width
            : (NSScreen.main?.frame.width ?? 1440)

        // hostView is non-flipped (origin bottom-left), so y=0 pins it to the
        // bottom; we drive the frame ourselves (no autoresizing).
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 0, height: Self.height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.alphaValue = Self.alpha
        effect.autoresizingMask = []
        hostView.addSubview(effect)
        bar = effect

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = seconds
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            ctx.allowsImplicitAnimation = true
            effect.animator().frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        }

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
        bar?.removeFromSuperview()
        bar = nil
    }

    private func fadeOut() {
        guard let bar = bar else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            bar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.bar?.removeFromSuperview()
            self?.bar = nil
        })
    }
}
