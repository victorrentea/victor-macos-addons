import Cocoa
import QuartzCore

/// Bottom-left status banner with presence gating: calls to `showOnPresence`
/// defer the actual fade-in until the laptop sees input again, so the user
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
    /// Uptime when the current wait began; any input newer than this is the
    /// user coming back (see `checkPresence`).
    private var presenceWaitStartedAt: CFTimeInterval = 0

    private var pendingText: String?
    private var pendingSound: NSSound?
    private var pendingVisibleDuration: TimeInterval = 5.0

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: false)
    }

    /// Schedule a banner to fade in on the next sign of life from the laptop —
    /// a keystroke counts, not only a mouse move. Plays `sound` when it appears.
    /// Stays visible `visibleDuration`, then fades out. Latest-wins.
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

    /// Show immediately, WITHOUT waiting for presence (mouse movement). Use for
    /// events the user is already looking at the screen for — e.g. a display
    /// reconfiguration, where the banner must appear the instant the layout
    /// changes rather than on the next mouse move. Latest-wins.
    ///
    /// `icon` rides in front of the words for banners whose subject is an app —
    /// the relay's, which used to spell `walkie:` out in letters. Set before the
    /// pill is built, since the icon changes how wide it has to be; an already
    /// visible pill keeps whatever icon it was built with, which is right for a
    /// banner being *updated* with the next line from the same source.
    func showNow(text: String, sound: NSSound?, visibleDuration: TimeInterval = 5.0,
                 icon: NSImage? = nil) {
        presenceTimer?.invalidate(); presenceTimer = nil
        pendingText = text
        pendingSound = sound
        pendingVisibleDuration = visibleDuration
        banner.icon = icon
        if banner.isVisible {
            banner.updateText(text)
        } else {
            banner.show(text: text)
        }
        sound?.play()
        scheduleFadeOut(after: visibleDuration)
        startHoverKeepAlive()
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
        presenceWaitStartedAt = CACurrentMediaTime()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkPresence()
        }
    }

    /// Presence is **any** input since the wait began, not just a moved cursor.
    /// A break that ends while Victor is away is over the moment he sits back
    /// down — and he sits back down by waking the Mac and typing, on a laptop
    /// whose trackpad may never be touched. The polled mouse position stays as
    /// the second opinion: it needs nothing from the event system at all, so a
    /// stuck event-source clock still cannot swallow the banner.
    private func checkPresence() {
        let pos = NSEvent.mouseLocation
        defer { lastMousePosition = pos }
        let inputAge = ScreenBlackout.secondsSinceLastInput()
        let sawInput = inputAge < (CACurrentMediaTime() - presenceWaitStartedAt)
        let mouseMoved = lastMousePosition.map { $0 != pos } ?? false
        if sawInput || mouseMoved {
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
