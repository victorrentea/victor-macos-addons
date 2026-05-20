import Cocoa

/// Bottom-left 5-second countdown shown at 18:00 before stopping the
/// transcription.
///
/// Presence-deferred: the countdown does **not** start at 18:00 if the user
/// is away. It waits for the first mouse movement, then begins the visible
/// 5→0 count. Hovering the pill cancels the countdown (keeps transcription
/// on). Reaching 0 without hover swaps the text to "stopped", plays the
/// stop chime, and fires the stop callback after a short visible pause.
final class TranscriptionCountdownOverlay {
    private weak var overlayPanel: OverlayPanel?

    private var backgroundLayer: CALayer?
    private var countdownLayer: CATextLayer?

    private var presenceTimer: Timer?
    private var countdownTimer: Timer?
    private var hoverPollTimer: Timer?

    private var presencePreviousMouse: NSPoint?
    private var remainingSeconds = 5
    private var mouseWasInside = false
    private var didFire = false

    private var onContinueCallback: (() -> Void)?
    private var onStopCallback: (() -> Void)?

    init(overlayPanel: OverlayPanel?) {
        self.overlayPanel = overlayPanel
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
        overlayInfo("Presence detected — starting 5s countdown")
        createOverlayLayers()
        updateCountdownText()
        startCountdownTimer()
        startHoverPolling()
    }

    private func createOverlayLayers() {
        guard let overlayView = overlayPanel?.contentView else { return }
        overlayView.wantsLayer = true
        guard let hostLayer = overlayView.layer else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first!

        let (bg, txt) = StatusBannerStyle.makeLayers(scale: screen.backingScaleFactor)
        hostLayer.addSublayer(bg)
        hostLayer.addSublayer(txt)
        backgroundLayer = bg
        countdownLayer = txt

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            bg.opacity = 1
            txt.opacity = 1
        }
    }

    private func updateCountdownText() {
        countdownLayer?.string = "ending in \(remainingSeconds)…"
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
        guard let bg = backgroundLayer,
              let overlayView = overlayPanel?.contentView,
              let window = overlayView.window else { return }
        let mousePos = NSEvent.mouseLocation
        let localPos = window.convertPoint(fromScreen: mousePos)
        let inside = bg.frame.contains(localPos)
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
        // play the stop chime, then fade out and notify.
        countdownLayer?.string = "stopped"
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
            backgroundLayer?.opacity = 0
            countdownLayer?.opacity = 0
        }, completionHandler: { [weak self] in
            self?.backgroundLayer?.removeFromSuperlayer()
            self?.countdownLayer?.removeFromSuperlayer()
            self?.backgroundLayer = nil
            self?.countdownLayer = nil
        })
    }
}
