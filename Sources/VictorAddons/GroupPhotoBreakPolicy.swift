import Foundation

/// Decides whether a break should trigger the 📸 Group Photo overlay. Two
/// independent reasons qualify it at its **start**:
///   • the **lunch** break — any break of 1 hour or longer, at any time of day;
///   • an **afternoon** break — a break of ≥ 10 minutes starting at 13:00 local
///     or later.
///
/// Morning coffee breaks shorter than lunch are intentionally ignored — nobody
/// wants a group photo an hour into the day. Pure + side-effect free so the rule
/// is unit-tested without a wall clock or any UI.
enum GroupPhotoBreakPolicy {
    /// A break at least this long (minutes) is treated as lunch and always qualifies.
    static let lunchMinutes = 60
    /// Local hour at/after which a shorter break still qualifies (the "afternoon").
    static let afternoonHour = 13
    /// Minimum length (minutes) for an afternoon break to qualify.
    static let afternoonMinMinutes = 10

    static func shouldPrompt(breakMinutes minutes: Int, at date: Date) -> Bool {
        if minutes >= lunchMinutes { return true }
        let hour = Calendar(identifier: .gregorian).dateComponents([.hour], from: date).hour ?? 0
        return hour >= afternoonHour && minutes >= afternoonMinMinutes
    }

    // MARK: - The second prompt, when the break ends

    /// A break that qualified at its start earns a **second** prompt when it is
    /// over. The one at the start is easy to act on and easy to lose — it lands
    /// while the room is already standing up to leave, and an hour later nobody
    /// remembers the photo was owed. The end of the break is when everyone is
    /// walking back in, which is the moment the shot actually happens; the
    /// banner is presence-gated, so if Victor is still out it waits and fades in
    /// on the first touch of the laptop rather than expiring into an empty room.

    /// Below this the "break" was never a break — the window was opened and shut
    /// (a misclick, a wrong duration) and a second prompt seconds after the first
    /// is just noise.
    static let endPromptMinElapsed: TimeInterval = 5 * 60

    /// The latch is persisted so it survives the redeploy Victor does *during*
    /// lunch, which means it can also outlive the break that set it (app quit,
    /// machine slept, break never formally closed). Past this age it is stale:
    /// a photo prompt at the end of tomorrow's coffee break, owed by yesterday's
    /// lunch, would be inexplicable.
    static let endPromptMaxAge: TimeInterval = 4 * 60 * 60

    /// Whether the break that started at `breakStartedAt` — which is set only
    /// when the *start* prompt actually fired — should prompt again now.
    static func shouldPromptAtEnd(breakStartedAt: Date?, now: Date) -> Bool {
        guard let breakStartedAt else { return false }
        let elapsed = now.timeIntervalSince(breakStartedAt)
        return elapsed >= endPromptMinElapsed && elapsed <= endPromptMaxAge
    }
}
