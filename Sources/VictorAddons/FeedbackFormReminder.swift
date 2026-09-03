import Cocoa

/// End-of-day nudge to collect feedback: a bottom-left pill asks
/// `Feedback form?`, and hovering it runs the same thing the 📝 menu item does
/// — Chrome clones, renames and publishes this session's survey, and the link
/// comes back to the clipboard, the 🔳 banner and the notes.
///
/// **Earlier than the wrap-up offer** (`SummaryReminder`, 16:45 / 17:15), and
/// deliberately so: the feedback link is only worth anything while the room is
/// still in it, whereas the summary is written once everyone has gone. Asking
/// for both at the same minute would put the link on screen at exactly the
/// moment people start packing up.
///
/// Gated on a live session, because the form is named after it: with no session
/// there is nothing to call the survey, and the offer would lead to an error
/// instead of a link.
final class FeedbackFormReminder {
    private let banner: BottomLeftBanner
    private let isSessionActive: () -> Bool
    private let onAccept: () -> Void
    private var tickTimer: Timer?
    /// Slot keys already fired, e.g. "2026-09-04 16:30". Persisted so the app's
    /// several restarts a day can't re-ask a question already answered.
    private var firedSlots: Set<String> = []
    private static let defaultsKey = "feedback.reminder.fired.slots"

    /// The times the offer appears at, both before the wrap-up slots.
    static let slots: [(hour: Int, minute: Int)] = [(16, 30), (17, 0)]

    /// How long the pill stays actionable, in *un-hovered* seconds (the
    /// countdown pauses while the cursor is on it). Same short window as the
    /// wrap-up offer: either Victor is at the Mac and reaches for it, or the
    /// second slot asks again.
    static let hoverWindow: TimeInterval = 10

    init(screensProvider: @escaping () -> [NSScreen],
         isSessionActive: @escaping () -> Bool,
         onAccept: @escaping () -> Void) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        self.isSessionActive = isSessionActive
        self.onAccept = onAccept
        firedSlots = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Begin watching the clock. Polls every 20s rather than scheduling a timer
    /// at the exact instant: a Mac that was asleep or shut at 16:30 never fires
    /// a scheduled timer at all, while a poll simply notices on the next tick
    /// that the slot is due and still inside its grace window.
    func start() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func tick() {
        guard let slot = SummaryReminderPolicy.dueSlot(now: Date(),
                                                       calendar: .current,
                                                       alreadyFired: firedSlots,
                                                       slots: Self.slots) else { return }
        /* The session gate is checked here rather than in the policy, and the
         * slot is NOT marked fired when it fails: a session that starts late
         * should still get the offer at the next tick inside the grace window,
         * instead of having silently burned its slot while the daemon was down. */
        guard isSessionActive() else { return }
        markFired(slot)
        offer(reason: slot)
    }

    private func markFired(_ slot: String) {
        firedSlots.insert(slot)
        // Only today's keys are ever consulted, so keep the list from growing
        // without bound across months of restarts.
        let today = SummaryReminderPolicy.dayKey(Date(), calendar: .current)
        firedSlots = firedSlots.filter { $0.hasPrefix(today) }
        UserDefaults.standard.set(Array(firedSlots), forKey: Self.defaultsKey)
    }

    /// Put the offer on screen. Hovering it (a deliberate, moving 2s dwell —
    /// see `HoverMotionGate`) asks Chrome for the form and floats the pill up;
    /// letting the window lapse drops it straight down, the codebase's standard
    /// accept/cancel pair.
    func offer(reason: String) {
        overlayInfo("feedback-reminder: offering the feedback form (\(reason))")
        var accepted = false
        banner.onHover = { [weak self, weak banner] in
            guard !accepted else { return }
            accepted = true
            banner?.dismissRisingFade()
            self?.onAccept()
        }
        banner.onHoverCountdownExpired = { [weak banner] in
            guard !accepted else { return }
            banner?.dismissSinking()
        }
        banner.show(text: "Feedback form?",
                    hoverCountdown: Self.hoverWindow,
                    hoverNudge: .up)
        StatusBannerSound.start?.play()
    }
}
