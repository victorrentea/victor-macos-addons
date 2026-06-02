import Cocoa

/// Bottom-left 5-second countdown shown at 18:00 before stopping the
/// transcription. Presence-deferred: waits for the first mouse movement
/// before beginning the visible count. Hovering cancels the countdown
/// (keeps transcription on). Reaching 0 without hover swaps text to
/// "stopped", plays the stop chime, and fires the stop callback after a
/// short visible pause. The background animates from bright red down to
/// neutral gray over the full countdown.
final class TranscriptionCountdownOverlay {
    private let banner: BottomLeftBanner

    private var presenceTimer: Timer?
    private var countdownTimer: Timer?
    private var presencePreviousMouse: NSPoint?
    private var remainingSeconds = 5
    private var didFire = false

    private var onContinueCallback: (() -> Void)?
    private var onStopCallback: (() -> Void)?

    private static let totalSeconds: TimeInterval = 5.0
    private static let redColor = NSColor.systemRed.withAlphaComponent(0.85)
    private static let grayColor = BottomLeftBanner.Style.defaultBackground

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        banner.onHover = { [weak self] in self?.fireContinue() }
    }

    /// Defer the countdown until the user is back at the laptop, then run
    /// the 5-second presence-aware shutdown sequence.
    func startCountdown(onContinue: @escaping () -> Void, onStop: @escaping () -> Void) {
        onContinueCallback = onContinue
        onStopCallback = onStop
        remainingSeconds = 5
        didFire = false
        overlayInfo("Bottom-left countdown armed — waiting for presence")
        startPresencePolling()
    }

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
            presenceTimer?.invalidate(); presenceTimer = nil
            beginVisibleCountdown()
        }
    }

    private func beginVisibleCountdown() {
        overlayInfo("Presence detected — starting 5s countdown")
        banner.show(text: "ending in \(remainingSeconds)…", backgroundColor: Self.redColor,
                    hoverHint: "Hover to continue", hoverCountdown: Self.totalSeconds)
        banner.updateBackgroundColor(Self.grayColor, animated: true, duration: Self.totalSeconds)
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        remainingSeconds -= 1
        if remainingSeconds > 0 {
            banner.updateText("ending in \(remainingSeconds)…")
        } else {
            countdownTimer?.invalidate(); countdownTimer = nil
            fireStop()
        }
    }

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
        banner.clearHint()  // no longer continuable — drop the "Hover to continue" hint
        banner.clearHoverCountdown()  // window closed — remove the orange progress bar
        banner.updateText("stopped")
        StatusBannerSound.stop?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.cleanup()
            self?.onStopCallback?()
        }
    }

    private func cleanup() {
        presenceTimer?.invalidate(); presenceTimer = nil
        countdownTimer?.invalidate(); countdownTimer = nil
        banner.dismiss()
    }
}
