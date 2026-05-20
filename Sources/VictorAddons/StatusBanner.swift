import Cocoa

/// Reusable bottom-left status banner.
///
/// Calls to `showOnPresence` defer the actual fade-in until mouse movement
/// is detected, so the user never misses a state change while they're away
/// from the laptop (toilet, phone call, etc.). Latest-wins: if another
/// `showOnPresence` arrives while one is pending or visible, the newer
/// content replaces it.
///
/// Visual style matches `TranscriptionCountdownOverlay`. Both share the
/// constants in `StatusBannerStyle`.
final class StatusBanner {
    private weak var overlayPanel: OverlayPanel?

    private var backgroundLayer: CALayer?
    private var textLayer: CATextLayer?

    private var presenceTimer: Timer?
    private var visibleTimer: Timer?
    private var lastMousePosition: NSPoint?

    private var pendingText: String?
    private var pendingSound: NSSound?
    private var pendingVisibleDuration: TimeInterval = 4.0
    private var isVisible = false

    init(overlayPanel: OverlayPanel?) {
        self.overlayPanel = overlayPanel
    }

    /// Schedule a banner to fade in after the next mouse movement.
    /// Plays `sound` when it appears. Stays visible `visibleDuration`,
    /// then fades out. Latest-wins.
    func showOnPresence(text: String, sound: NSSound?, visibleDuration: TimeInterval = 4.0) {
        pendingText = text
        pendingSound = sound
        pendingVisibleDuration = visibleDuration

        if isVisible {
            // Already on screen: swap text in place, reset the auto-fade timer,
            // re-play the sound to alert the user that something else happened.
            textLayer?.string = text
            sound?.play()
            scheduleFadeOut(after: visibleDuration)
            return
        }
        startPresencePolling()
    }

    /// Dismiss anything pending or visible without firing.
    func dismiss() {
        presenceTimer?.invalidate()
        presenceTimer = nil
        visibleTimer?.invalidate()
        visibleTimer = nil
        pendingText = nil
        pendingSound = nil
        lastMousePosition = nil
        if isVisible {
            fadeOutAndRemove()
        }
    }

    // MARK: - Presence

    private func startPresencePolling() {
        presenceTimer?.invalidate()
        lastMousePosition = NSEvent.mouseLocation
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkPresence()
        }
    }

    private func checkPresence() {
        let pos = NSEvent.mouseLocation
        defer { lastMousePosition = pos }
        guard let last = lastMousePosition else { return }
        if last != pos {
            presenceTimer?.invalidate()
            presenceTimer = nil
            revealBanner()
        }
    }

    // MARK: - Visual

    private func revealBanner() {
        guard let text = pendingText else { return }
        let sound = pendingSound
        createLayersIfNeeded()
        textLayer?.string = text
        fadeIn()
        sound?.play()
        scheduleFadeOut(after: pendingVisibleDuration)
        isVisible = true
    }

    private func createLayersIfNeeded() {
        guard backgroundLayer == nil, textLayer == nil else { return }
        guard let overlayView = overlayPanel?.contentView else { return }
        overlayView.wantsLayer = true
        guard let hostLayer = overlayView.layer else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first!

        let (bg, txt) = StatusBannerStyle.makeLayers(scale: screen.backingScaleFactor)
        hostLayer.addSublayer(bg)
        hostLayer.addSublayer(txt)
        backgroundLayer = bg
        textLayer = txt
    }

    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            backgroundLayer?.opacity = 1
            textLayer?.opacity = 1
        }
    }

    private func scheduleFadeOut(after seconds: TimeInterval) {
        visibleTimer?.invalidate()
        visibleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.fadeOutAndRemove()
        }
    }

    private func fadeOutAndRemove() {
        visibleTimer?.invalidate()
        visibleTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            self.backgroundLayer?.opacity = 0
            self.textLayer?.opacity = 0
        }, completionHandler: { [weak self] in
            self?.backgroundLayer?.removeFromSuperlayer()
            self?.textLayer?.removeFromSuperlayer()
            self?.backgroundLayer = nil
            self?.textLayer = nil
            self?.isVisible = false
            self?.pendingText = nil
            self?.pendingSound = nil
        })
    }
}

/// Shared visual constants. Both `StatusBanner` and
/// `TranscriptionCountdownOverlay` use this to stay consistent.
///
/// 30% of the original size, flush against the bottom-left screen edge,
/// square corners.
enum StatusBannerStyle {
    static let fontSize: CGFloat = 12
    static let padding: CGFloat = 7
    static let cornerRadius: CGFloat = 0
    static let textWidth: CGFloat = 144
    static let textHeight: CGFloat = 24
    static let backgroundColor = NSColor.gray.withAlphaComponent(0.6).cgColor
    static let textColor = NSColor.white.cgColor

    static func makeLayers(scale: CGFloat) -> (CALayer, CATextLayer) {
        let totalWidth = textWidth + padding * 2
        let totalHeight = textHeight + padding * 2

        let bg = CALayer()
        bg.frame = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        bg.backgroundColor = backgroundColor
        bg.cornerRadius = cornerRadius
        bg.opacity = 0

        let text = CATextLayer()
        text.frame = CGRect(x: padding, y: padding / 2, width: textWidth, height: textHeight)
        text.fontSize = fontSize
        text.foregroundColor = textColor
        text.alignmentMode = .left
        text.contentsScale = scale
        text.opacity = 0
        return (bg, text)
    }
}

/// Built-in macOS system sounds used as start/stop chimes. These live in
/// `/System/Library/Sounds/`. Can be swapped for bundled assets later.
enum StatusBannerSound {
    static let start = NSSound(named: NSSound.Name("Pop"))
    static let stop = NSSound(named: NSSound.Name("Submarine"))
}
