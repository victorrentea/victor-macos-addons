import Cocoa

/// Bottom-left 5-second countdown shown at 18:00 before stopping the
/// transcription, on **every** connected screen.
///
/// Presence-deferred: the countdown does **not** start at 18:00 if the user
/// is away. It waits for the first mouse movement, then begins the visible
/// 5→0 count. Hovering any of the bottom-left pills cancels the countdown
/// (keeps transcription on). Reaching 0 without hover swaps the text to
/// "stopped", plays the stop chime, and fires the stop callback after a
/// short visible pause.
///
/// During the 5-second countdown the background animates from a bright red
/// down to the standard gray of `StatusBanner`, so the visual urgency
/// matches the audible cue while still landing on the same neutral look as
/// the other notifications when it finishes.
final class TranscriptionCountdownOverlay {
    private let panelsProvider: () -> [OverlayPanel]

    private struct PanelLayers {
        let panel: OverlayPanel
        let bg: CALayer
        let text: CATextLayer
    }
    private var perScreen: [PanelLayers] = []

    private var presenceTimer: Timer?
    private var countdownTimer: Timer?
    private var hoverPollTimer: Timer?

    private var presencePreviousMouse: NSPoint?
    private var remainingSeconds = 5
    private var mouseWasInside = false
    private var didFire = false

    private var onContinueCallback: (() -> Void)?
    private var onStopCallback: (() -> Void)?

    private static let totalSeconds: TimeInterval = 5.0
    private static let redColor: CGColor =
        NSColor.systemRed.withAlphaComponent(0.85).cgColor

    init(panelsProvider: @escaping () -> [OverlayPanel]) {
        self.panelsProvider = panelsProvider
    }

    /// Defer the countdown until the user is back at the laptop, then run
    /// the 5-second presence-aware shutdown sequence.
    func startCountdown(onContinue: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onContinueCallback = onContinue
        self.onStopCallback = onStop
        remainingSeconds = 5
        didFire = false
        overlayInfo("Bottom-left countdown armed — waiting for presence")
        startPresencePolling()
    }

    // MARK: - Presence

    private func startPresencePolling() {
        presenceTimer?.invalidate()
        presencePreviousMouse = NSEvent.mouseLocation
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkPresence()
        }
    }

    private func checkPresence() {
        let pos = NSEvent.mouseLocation
        defer { presencePreviousMouse = pos }
        guard let last = presencePreviousMouse else { return }
        if last != pos {
            presenceTimer?.invalidate()
            presenceTimer = nil
            beginVisibleCountdown()
        }
    }

    // MARK: - Visible countdown

    private func beginVisibleCountdown() {
        let panels = panelsProvider()
        overlayInfo("Presence detected — starting 5s countdown on \(panels.count) screen(s)")
        createOverlayLayers(panels: panels)
        updateCountdownText()
        startCountdownTimer()
        startHoverPolling()
    }

    private func createOverlayLayers(panels: [OverlayPanel]) {
        for panel in panels {
            guard let overlayView = panel.contentView else { continue }
            overlayView.wantsLayer = true
            guard let hostLayer = overlayView.layer else { continue }
            let scale = panel.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0

            let (bg, txt) = StatusBannerStyle.makeLayers(scale: scale)

            // Set the model background to the final (gray) value so that when
            // the explicit animation finishes the layer stays gray — matching
            // the other StatusBanner notifications.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bg.backgroundColor = StatusBannerStyle.backgroundColor
            CATransaction.commit()

            hostLayer.addSublayer(bg)
            hostLayer.addSublayer(txt)
            perScreen.append(PanelLayers(panel: panel, bg: bg, text: txt))

            // Opacity fade-in (matches existing 0.3s reveal).
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                bg.opacity = 1
                txt.opacity = 1
            }

            // Red → gray over the full countdown, in parallel with the text
            // ticking down. Linear so the urgency drops at a constant rate.
            let colorAnim = CABasicAnimation(keyPath: "backgroundColor")
            colorAnim.fromValue = Self.redColor
            colorAnim.toValue = StatusBannerStyle.backgroundColor
            colorAnim.duration = Self.totalSeconds
            colorAnim.timingFunction = CAMediaTimingFunction(name: .linear)
            colorAnim.fillMode = .forwards
            bg.add(colorAnim, forKey: "redToGray")
        }
    }

    private func updateCountdownText() {
        for layers in perScreen {
            layers.text.string = "ending in \(remainingSeconds)…"
        }
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.countdownTick()
        }
    }

    private func countdownTick() {
        remainingSeconds -= 1
        if remainingSeconds > 0 {
            updateCountdownText()
        } else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            fireStop()
        }
    }

    // MARK: - Hover

    private func startHoverPolling() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkHover()
        }
    }

    private func checkHover() {
        let mousePos = NSEvent.mouseLocation
        var inside = false
        for layers in perScreen {
            guard let window = layers.panel.contentView?.window else { continue }
            let localPos = window.convertPoint(fromScreen: mousePos)
            if layers.bg.frame.contains(localPos) {
                inside = true
                break
            }
        }
        if inside && !mouseWasInside {
            mouseWasInside = true
            fireContinue()
        } else if !inside {
            mouseWasInside = false
        }
    }

    // MARK: - Outcomes

    private func fireContinue() {
        guard !didFire else { return }
        didFire = true
        overlayInfo("Hover during countdown — keeping transcription on")
        cleanup()
        onContinueCallback?()
    }

    private func fireStop() {
        guard !didFire else { return }
        didFire = true
        overlayInfo("Countdown reached 0 — stopping")
        // Swap text to "stopped" briefly so the user knows what happened,
        // play the stop chime, then fade out and notify. Background is
        // already gray (red→gray animation just completed).
        for layers in perScreen {
            layers.text.string = "stopped"
        }
        StatusBannerSound.stop?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.cleanup()
            self?.onStopCallback?()
        }
    }

    private func cleanup() {
        presenceTimer?.invalidate(); presenceTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
        hoverPollTimer?.invalidate(); hoverPollTimer = nil
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
        })
    }
}
