import AppKit
import QuartzCore

/// Opaque-black covers over EVERY connected display, held until the next user
/// input.
///
/// Shown whenever the ☕️ Break timer *closes* — the ✕ button, the countdown
/// expiring after the gong, or a programmatic close — no matter whether the
/// timer was in its fullscreen "break screen" state or a small corner watch.
/// The point is the room: when the break ends while Victor is still away, the
/// projector must keep showing nothing instead of snapping back to his desktop
/// (mail, slides, terminal). The first mouse move / keystroke *after* the covers
/// appear takes them down — so "black until I come back" is literally the rule.
///
/// Deliberately holds **no** wake lock (unlike the fullscreen break screen,
/// which must stay readable): once the timer is gone there is nothing to keep
/// visible, so normal display sleep is welcome — and the same input that wakes
/// the display also dismisses these covers.
final class ScreenBlackout {
    static let shared = ScreenBlackout()

    /// Pure decision, unit-tested: the covers come down only on input that
    /// happened *after* they went up. The click that hit ✕ landed a moment
    /// BEFORE `startedAt`, so it never dismisses its own blackout.
    enum Policy {
        static func shouldDismiss(now: CFTimeInterval,
                                  startedAt: CFTimeInterval,
                                  idleSeconds: CFTimeInterval) -> Bool {
            let lastInputAt = now - idleSeconds
            return lastInputAt > startedAt
        }

        /// How recently the user must have touched the Mac, at the moment the
        /// countdown hits zero, for the post-break blackout to be skipped.
        static let atTheMacWindow: CFTimeInterval = 10

        /// Whether the countdown reaching zero should black the displays out at
        /// all. The blackout exists for the break that ends while Victor is
        /// still out of the room — but when he was working at the Mac in the
        /// last `atTheMacWindow` seconds he is plainly back, and the covers
        /// would only flash black over what he is doing until his next mouse
        /// move takes them down again. Sampled at expiry (not at the close that
        /// follows the gong ~18s later), so the gong itself can't count as
        /// "he's here".
        static func shouldBlackoutOnExpiry(idleSecondsAtExpiry: CFTimeInterval) -> Bool {
            idleSecondsAtExpiry > atTheMacWindow
        }
    }

    private static let defaultFadeIn: TimeInterval = 0.35
    private static let fadeOut: TimeInterval = 0.3
    private static let pollInterval: TimeInterval = 0.1

    private var panels: [NSPanel] = []
    private var poll: Timer?
    private var startedAt: CFTimeInterval = 0

    var isShowing: Bool { !panels.isEmpty }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    /// Black out every display until the user comes back. `fadeIn: 0` keeps the
    /// transition seamless when the screen was ALREADY black (closing the
    /// fullscreen break screen) — a fade there would flash the desktop first.
    func show(fadeIn: TimeInterval = defaultFadeIn) {
        startedAt = CACurrentMediaTime()
        guard !isShowing else { return }        // already black: just extend the wait
        buildPanels(fadeIn: fadeIn)
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// Take the covers down (fading out), e.g. on input or when a new break opens.
    func dismiss() {
        poll?.invalidate(); poll = nil
        let dying = panels
        panels.removeAll()
        guard !dying.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeOut
            for p in dying { p.animator().alphaValue = 0 }
        } completionHandler: {
            for p in dying { p.orderOut(nil) }
        }
    }

    private func tick() {
        if Policy.shouldDismiss(now: CACurrentMediaTime(),
                                startedAt: startedAt,
                                idleSeconds: Self.secondsSinceLastInput()) {
            dismiss()
        }
    }

    /// A projector plugged/unplugged while the covers are up would leave the new
    /// display uncovered — rebuild the set in place (no fade, the rest is already
    /// black).
    @objc private func screenParametersChanged() {
        guard isShowing else { return }
        let old = panels
        panels.removeAll()
        buildPanels(fadeIn: 0)
        for p in old { p.orderOut(nil) }
    }

    private func buildPanels(fadeIn: TimeInterval) {
        for screen in NSScreen.screens {
            let p = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = true
            p.hasShadow = false
            p.ignoresMouseEvents = true      // click-through: a stuck cover can never trap the Mac
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            p.contentView = content
            p.setFrame(screen.frame, display: false)
            p.alphaValue = fadeIn > 0 ? 0 : 1
            p.orderFrontRegardless()
            if fadeIn > 0 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = fadeIn
                    p.animator().alphaValue = 1
                }
            }
            panels.append(p)
        }
    }

    /// Seconds since the last user input of any kind (mouse or keyboard).
    static func secondsSinceLastInput() -> CFTimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .leftMouseDragged, .keyDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 999
    }
}
