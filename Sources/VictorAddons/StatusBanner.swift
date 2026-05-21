import Cocoa

/// Reusable bottom-left status banner, shown on **every** connected screen.
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
    private let panelsProvider: () -> [OverlayPanel]

    private struct PanelLayers {
        let panel: OverlayPanel
        let bg: CALayer
        let text: CATextLayer
    }
    private var perScreen: [PanelLayers] = []

    private var presenceTimer: Timer?
    private var visibleTimer: Timer?
    private var lastMousePosition: NSPoint?

    private var pendingText: String?
    private var pendingSound: NSSound?
    private var pendingVisibleDuration: TimeInterval = 4.0
    private var isVisible = false

    init(panelsProvider: @escaping () -> [OverlayPanel]) {
        self.panelsProvider = panelsProvider
    }

    /// Schedule a banner to fade in after the next mouse movement.
    /// Plays `sound` when it appears. Stays visible `visibleDuration`,
    /// then fades out. Latest-wins.
    func showOnPresence(text: String, sound: NSSound?, visibleDuration: TimeInterval = 4.0) {
        pendingText = text
        pendingSound = sound
        pendingVisibleDuration = visibleDuration

        if isVisible {
            // Already on screen: swap text in place on all screens, reset the
            // auto-fade timer, re-play the sound to alert the user that
            // something else happened.
            for layers in perScreen {
                layers.text.string = text
            }
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
        for layers in perScreen {
            layers.text.string = text
        }
        fadeIn()
        sound?.play()
        scheduleFadeOut(after: pendingVisibleDuration)
        isVisible = true
    }

    private func createLayersIfNeeded() {
        guard perScreen.isEmpty else { return }
        for panel in panelsProvider() {
            guard let overlayView = panel.contentView else { continue }
            overlayView.wantsLayer = true
            guard let hostLayer = overlayView.layer else { continue }
            let scale = panel.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0

            let (bg, txt) = StatusBannerStyle.makeLayers(scale: scale)
            hostLayer.addSublayer(bg)
            hostLayer.addSublayer(txt)
            perScreen.append(PanelLayers(panel: panel, bg: bg, text: txt))
        }
    }

    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            for layers in perScreen {
                layers.bg.opacity = 1
                layers.text.opacity = 1
            }
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
            for layers in self.perScreen {
                layers.bg.opacity = 0
                layers.text.opacity = 0
            }
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            for layers in self.perScreen {
                layers.bg.removeFromSuperlayer()
                layers.text.removeFromSuperlayer()
            }
            self.perScreen.removeAll()
            self.isVisible = false
            self.pendingText = nil
            self.pendingSound = nil
        })
    }
}

/// Shared visual constants. Both `StatusBanner` and
/// `TranscriptionCountdownOverlay` use this to stay consistent.
///
/// 30% of the original size, flush against the bottom-left screen edge,
/// square corners.
enum StatusBannerStyle {
    static let fontSize: CGFloat = 36
    static let leftPadding: CGFloat = 20
    static let rightPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 0
    static let textWidth: CGFloat = 448
    static let boxHeight: CGFloat = 80
    static let textRenderHeight: CGFloat = 50  // tall enough for descenders
    static let backgroundColor = NSColor.gray.withAlphaComponent(0.6).cgColor
    static let textColor = NSColor.white.cgColor

    static func makeLayers(scale: CGFloat) -> (CALayer, CATextLayer) {
        let totalWidth = leftPadding + textWidth + rightPadding

        let bg = CALayer()
        bg.frame = CGRect(x: 0, y: 0, width: totalWidth, height: boxHeight)
        bg.backgroundColor = backgroundColor
        bg.cornerRadius = cornerRadius
        bg.opacity = 0

        let text = CATextLayer()
        text.frame = CGRect(
            x: leftPadding,
            y: (boxHeight - textRenderHeight) / 2,
            width: textWidth,
            height: textRenderHeight
        )
        text.font = NSFont.boldSystemFont(ofSize: fontSize)
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
