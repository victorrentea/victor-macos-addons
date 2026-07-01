import Foundation

/// Decides whether the **start of a break** should trigger the 📸 Group Photo
/// overlay. Two independent reasons qualify:
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
}
