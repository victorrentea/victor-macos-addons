import Foundation

/// Pure decisions behind the 📶 roaming-allowance warning (`RoamingWarning`).
///
/// The phone owns the numbers — the plan's ceiling, the reset day, the 15%
/// threshold — and sends them with every reading (see `PhoneRoamingMonitor`
/// and `RoamingStatusChannel.kt` in `victor-phone-addons`). This side only
/// decides *whether to show it now*: once a day, on a day the phone has been
/// roaming, until Victor dismisses it.
enum RoamingWarningPolicy {

    struct Reading: Equatable {
        /// Roaming bytes since the plan's last reset day, the whole phone.
        let cycleTotal: Int64
        /// The part of `cycleTotal` that went through the hotspot.
        let cycleHotspot: Int64
        /// Roaming bytes since the phone's midnight.
        let today: Int64
        let roamingNow: Bool
        let limit: Int64
        let lowFraction: Double
        let nextReset: Date
        /// When the phone took the reading.
        let readAt: Date

        var remaining: Int64 { max(0, limit - cycleTotal) }
        var remainingFraction: Double { limit > 0 ? Double(remaining) / Double(limit) : 0 }
        /// Same rule as the phone's `Reading.roamingToday`: traffic in roaming
        /// since midnight, or on a roaming network right now (the morning,
        /// before anything has been counted).
        var roamingToday: Bool { roamingNow || today > 0 }
        var low: Bool { roamingToday && remainingFraction < lowFraction }
    }

    /// A reading this old says nothing about *now*: the phone may have gone
    /// home, or out of Bluetooth range for the day. Three missed polls.
    static let staleAfter: TimeInterval = 60 * 60

    /// One line of JSON from the phone. Nil for anything that is not a
    /// complete reading — including the phone's own `{"error": …}` answer when
    /// it has lost Usage access, which must not read as "nothing used".
    static func parse(_ line: String) -> Reading? {
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["error"] == nil,
              let total = (o["cycleTotal"] as? NSNumber)?.int64Value,
              let today = (o["today"] as? NSNumber)?.int64Value,
              let limit = (o["limit"] as? NSNumber)?.int64Value, limit > 0,
              let readAt = (o["readAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return Reading(
            cycleTotal: total,
            cycleHotspot: (o["cycleHotspot"] as? NSNumber)?.int64Value ?? 0,
            today: today,
            roamingNow: (o["roamingNow"] as? Bool) ?? false,
            limit: limit,
            lowFraction: (o["lowFraction"] as? NSNumber)?.doubleValue ?? 0.15,
            nextReset: Date(timeIntervalSince1970: ((o["nextReset"] as? NSNumber)?.doubleValue ?? 0) / 1000),
            readAt: Date(timeIntervalSince1970: readAt / 1000))
    }

    /// Show the warning now? Only for a fresh reading taken *today* (its
    /// `today` counter is the phone's day, so yesterday's reading would claim
    /// yesterday's roaming), and not once it has been dismissed today — the
    /// dismissal is per day, so the next roaming day asks again.
    static func shouldWarn(_ r: Reading?, now: Date, dismissedDay: String?, calendar: Calendar) -> Bool {
        guard let r, r.low else { return false }
        guard now.timeIntervalSince(r.readAt) < staleAfter,
              calendar.isDate(r.readAt, inSameDayAs: now) else { return false }
        return dismissedDay != dayKey(now, calendar: calendar)
    }

    static func text(_ r: Reading) -> String {
        let pct = Int((r.remainingFraction * 100).rounded(.down))
        return "📶 Roaming: \(gb(r.remaining)) left (\(pct)%)"
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
