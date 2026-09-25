import Cocoa

/// 📶 The roaming allowance is nearly gone: a red bottom-left pill,
/// `📶 Roaming: 1.8 GB left (13%)`, on a day the phone has been roaming and
/// under 15% of the plan's 13.7 GB is left (both numbers are the phone's; see
/// `RoamingWarningPolicy`).
///
/// **It stays until Victor dismisses it**, by hovering it (the codebase's
/// "put away" gesture: a deliberate moving dwell, then the pill sinks). It does
/// not time out — a warning that leaves on its own is one nobody saw. The
/// dismissal lasts for the rest of the day only, persisted so the app's
/// restarts don't bring it back; the next roaming day asks again.
///
/// A banner and not a native notification for the same reason as the others
/// here: macOS suppresses this app's notifications while a deck is fullscreen.
final class RoamingWarning {
    private let banner: BottomLeftBanner
    private var reading: RoamingWarningPolicy.Reading?
    private var dayTimer: Timer?
    private static let dismissedKey = "roaming.warning.dismissed.day"
    private static let color = NSColor.systemRed.withAlphaComponent(0.85)

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
    }

    func start() {
        // The day flips under a pill nobody dismissed, and a stale reading has
        // to take it down: re-decide on a clock, not only on new readings.
        dayTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    func update(_ r: RoamingWarningPolicy.Reading?) {
        reading = r
        evaluate()
    }

    private var dismissedDay: String? {
        UserDefaults.standard.string(forKey: Self.dismissedKey)
    }

    private func evaluate() {
        let now = Date()
        guard RoamingWarningPolicy.shouldWarn(reading, now: now, dismissedDay: dismissedDay,
                                              calendar: .current), let r = reading else {
            if banner.isVisible { banner.dismiss() }
            return
        }
        let text = RoamingWarningPolicy.text(r)
        if banner.isVisible {
            banner.updateText(text)
            return
        }
        banner.onHover = { [weak self] in self?.dismissForToday() }
        banner.show(text: text, backgroundColor: Self.color, hoverNudge: .down)
        NSSound(named: NSSound.Name("Basso"))?.play()
        overlayInfo("📶 roaming warning shown: \(text)")
    }

    private func dismissForToday() {
        UserDefaults.standard.set(RoamingWarningPolicy.dayKey(Date(), calendar: .current),
                                  forKey: Self.dismissedKey)
        banner.dismissSinking()
        overlayInfo("📶 roaming warning dismissed for today")
    }

    /// `GET /test/roaming/reset-dismissal` — forget today's dismissal.
    func resetDismissal() {
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        evaluate()
    }
}
