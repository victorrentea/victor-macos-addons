import Cocoa

/// End-of-day nudge to write up the training: at **16:45** and **17:15** a
/// bottom-left pill asks `Start summarization?`, and hovering it opens an
/// **interactive** `claude` in a new Terminal at `~/workspace`, primed with the
/// training-summarizer prompt.
///
/// Interactive, not `-p`, on purpose — unlike the break-delta run
/// (`BreakSummaryLauncher`), the wrap-up is a conversation: Victor reads what
/// came out, corrects it, asks for another pass. So this hands him a live
/// session and gets out of the way.
///
/// Two slots rather than one because the first is a *pre-*announcement — 16:45
/// is usually mid-sentence in the last section, so missing it is expected; 17:15
/// catches the same day once the room is actually done. Each fires at most once
/// per day (see `SummaryReminderPolicy`).
final class SummaryReminder {
    private let banner: BottomLeftBanner
    private var tickTimer: Timer?
    /// Slot keys already fired, e.g. "2026-08-06 16:45". Persisted so the app's
    /// several restarts a day can't re-ask a question already answered.
    private var firedSlots: Set<String> = []
    private static let defaultsKey = "summary.reminder.fired.slots"

    /// How long the pill stays actionable, in *un-hovered* seconds (the
    /// countdown pauses while the cursor is on it) — the same short window as
    /// the notes banner. A wrap-up offer is glanceable: either Victor is at the
    /// Mac and reaches for it, or he isn't and the 17:15 slot asks again.
    /// Lingering longer would just park a pill over the projected screen.
    static let hoverWindow: TimeInterval = 10

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        firedSlots = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Begin watching the clock. Polls every 20s rather than scheduling a timer
    /// at the exact instant: a Mac that was asleep or shut at 16:45 never fires
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
                                                       alreadyFired: firedSlots) else { return }
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
    /// see `HoverMotionGate`) launches the session and floats the pill up;
    /// letting the window lapse drops it straight down, the codebase's standard
    /// accept/cancel pair.
    func offer(reason: String) {
        overlayInfo("summary-reminder: offering wrap-up (\(reason))")
        var launched = false
        banner.onHover = { [weak self, weak banner] in
            guard !launched else { return }
            launched = true
            banner?.dismissRisingFade()
            self?.launchInteractiveClaude()
        }
        banner.onHoverCountdownExpired = { [weak banner] in
            guard !launched else { return }
            banner?.dismissSinking()
        }
        banner.show(text: "Start summarization?",
                    hoverCountdown: Self.hoverWindow,
                    hoverNudge: .up)
        StatusBannerSound.start?.play()
    }

    /// Open a NEW Terminal window with an interactive `claude` in `~/workspace`,
    /// primed with the training-summarizer prompt.
    ///
    /// `env -u ANTHROPIC_API_KEY` for the same reason the break-delta and the
    /// mail agent do it: the key in the environment is a depleted API account,
    /// while Victor's Claude subscription is the one that should pay. Nothing
    /// waits on this window — it is his session now, so there is no sentinel and
    /// no auto-close.
    private func launchInteractiveClaude() {
        let cwd = "\(NSHomeDirectory())/workspace"
        // Single-quoted inside the shell command, which is itself inside an
        // AppleScript string — so the prompt must contain no quote of either
        // kind. It doesn't, and a slash-command is all claude needs to load the
        // skill's own instructions.
        let command = "cd '\(cwd)' && env -u ANTHROPIC_API_KEY claude '\(Self.prompt)'"
        let osa = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", osa]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            overlayInfo("summary-reminder: launched interactive claude in \(cwd)")
        } catch {
            overlayError("summary-reminder: failed to open Terminal — \(error.localizedDescription)")
        }
    }

    /// The slash-command that loads the training-summarizer skill.
    static let prompt = "/victor-skills:training-summarizer"
}

/// When the wrap-up offer is due. Pure so the schedule can be tested without
/// waiting for 16:45 to come around.
enum SummaryReminderPolicy {
    /// Local times the offer appears at.
    static let slots: [(hour: Int, minute: Int)] = [(16, 45), (17, 15)]

    /// How late a slot may still fire. The app restarts several times a day, so
    /// a slot that came due while it was down (a rebuild, a wedged relaunch)
    /// would otherwise be lost entirely; within the window it simply asks a few
    /// minutes late, which for a wrap-up reminder is the same reminder.
    static let graceMinutes = 10

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func slotKey(_ date: Date, calendar: Calendar, hour: Int, minute: Int) -> String {
        String(format: "%@ %02d:%02d", dayKey(date, calendar: calendar), hour, minute)
    }

    /// Whether `date` is a working day (Mon–Fri). Training happens on weekdays,
    /// so a Saturday afternoon has no session to write up and the offer would
    /// only be an interruption. Public holidays are deliberately NOT modelled —
    /// they'd need a calendar per country Victor happens to be in, and an
    /// unwanted pill on one such afternoon costs a glance.
    static func isWorkday(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday … 7 = Saturday
        return weekday != 1 && weekday != 7
    }

    /// The key of the slot that should fire right now, or nil. A slot is due on
    /// a working day, from its own minute until `graceMinutes` later, and only
    /// if it hasn't already fired today.
    static func dueSlot(now: Date, calendar: Calendar, alreadyFired: Set<String>) -> String? {
        guard isWorkday(now, calendar: calendar) else { return nil }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        guard let h = c.hour, let m = c.minute else { return nil }
        let nowMinutes = h * 60 + m
        for slot in slots {
            let slotMinutes = slot.hour * 60 + slot.minute
            guard nowMinutes >= slotMinutes, nowMinutes <= slotMinutes + graceMinutes else { continue }
            let key = slotKey(now, calendar: calendar, hour: slot.hour, minute: slot.minute)
            if !alreadyFired.contains(key) { return key }
        }
        return nil
    }
}
