import Foundation

/// When the tablet blinks about the phone: a pure decision over `PhoneCharge`'s reading.
///
/// It used to read Soduto's "Low Battery" notification out of macOS's notification store,
/// because Soduto published the phone's battery nowhere else. Victor Net has known the real
/// percentage since 2026-10-29, on every network, so that needs neither Soduto nor Full Disk
/// Access any more (2026-11-06).
enum PhoneBatteryPolicy {

    /// Only a phone under this charge is worth blinking a tablet about. The tablet applies
    /// the same floor on its side, so an old build of either half is harmless on its own.
    static let warnBelowPct = 30

    /// A phone that went flat stops reporting, and its last reading must not blink the
    /// tablet all night.
    static let staleAfter: TimeInterval = 90 * 60

    /// Whether the tablet should be blinking right now.
    static func shouldWarn(_ reading: PhoneCharge.Reading?, now: Date) -> Bool {
        guard let reading, !reading.charging, (0..<warnBelowPct).contains(reading.pct) else { return false }
        let age = TimeInterval(reading.ageS) + max(0, now.timeIntervalSince(reading.fetchedAt))
        return age <= staleAfter
    }

    /// The `/ping` fields the tablet reads, as a fragment to splice into the hand-built ping
    /// JSON (leading comma included; only a bool and an int, so nothing here can forge JSON).
    static func pingFields(for reading: PhoneCharge.Reading?, now: Date) -> String {
        let warn = shouldWarn(reading, now: now)
        let pct = warn ? (reading?.pct ?? -1) : -1
        return ",\"phoneBatteryLow\":\(warn),\"phoneBatteryPct\":\(pct)"
    }
}
