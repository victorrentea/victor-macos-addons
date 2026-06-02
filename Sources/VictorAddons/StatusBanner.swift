import Cocoa

/// Bottom-left status banner with presence gating: calls to `showOnPresence`
/// defer the actual fade-in until mouse movement is detected, so the user
/// never misses a state change while they're away from the laptop. Latest-
/// wins: a new call while already visible swaps text in place and resets
/// the auto-fade timer.
///
/// Rendering lives in `BottomLeftBanner`; this class only owns the state
/// machine.
final class StatusBanner {
    private let banner: BottomLeftBanner
    private var presenceTimer: Timer?
    private var visibleTimer: Timer?
    private var hoverPollTimer: Timer?
    private var lastMousePosition: NSPoint?

    private var pendingText: String?
    private var pendingSound: NSSound?
    private var pendingVisibleDuration: TimeInterval = 5.0

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: false)
    }

    /// Schedule a banner to fade in after the next mouse movement.
    /// Plays `sound` when it appears. Stays visible `visibleDuration`,
    /// then fades out. Latest-wins.
    func showOnPresence(text: String, sound: NSSound?, visibleDuration: TimeInterval = 5.0) {
        pendingText = text
        pendingSound = sound
        pendingVisibleDuration = visibleDuration

        if banner.isVisible {
            banner.updateText(text)
            sound?.play()
            scheduleFadeOut(after: visibleDuration)
            startHoverKeepAlive()
            return
        }
        startPresencePolling()
    }

    /// Dismiss anything pending or visible without firing.
    func dismiss() {
        presenceTimer?.invalidate(); presenceTimer = nil
        visibleTimer?.invalidate(); visibleTimer = nil
        hoverPollTimer?.invalidate(); hoverPollTimer = nil
        pendingText = nil
        pendingSound = nil
        lastMousePosition = nil
        banner.dismiss()
    }

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
            presenceTimer?.invalidate(); presenceTimer = nil
            revealBanner()
        }
    }

    private func revealBanner() {
        guard let text = pendingText else { return }
        banner.show(text: text)
        pendingSound?.play()
        scheduleFadeOut(after: pendingVisibleDuration)
        startHoverKeepAlive()
    }

    private func scheduleFadeOut(after seconds: TimeInterval) {
        visibleTimer?.invalidate()
        visibleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hoverPollTimer?.invalidate(); self?.hoverPollTimer = nil
            self?.banner.dismiss()
            self?.pendingText = nil
            self?.pendingSound = nil
        }
    }

    /// While the banner is visible, hovering the cursor over it resets the
    /// auto-fade countdown: the box stays up as long as the cursor is on it,
    /// and only fades `pendingVisibleDuration` (e.g. 7s) after the cursor
    /// leaves. Polls position rather than capturing mouse events so the
    /// banner stays click-through.
    private func startHoverKeepAlive() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.banner.isMouseInside else { return }
            self.scheduleFadeOut(after: self.pendingVisibleDuration)
        }
    }
}

/// Built-in macOS system sounds used as start/stop chimes. These live in
/// `/System/Library/Sounds/`. Can be swapped for bundled assets later.
enum StatusBannerSound {
    static let start = NSSound(named: NSSound.Name("Pop"))
    static let stop = NSSound(named: NSSound.Name("Submarine"))
}
