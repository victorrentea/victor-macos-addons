import Foundation

/// Pure decisions behind the 📱 phone-low-battery mirror to the tablet.
///
/// **Why the notification and not a battery level.** Soduto speaks KDE Connect to
/// the paired Android but keeps the peer's battery status purely in memory — it
/// is in no preference file, no menu item and no API we can reach from another
/// process (`BatteryService` builds no menu; the only thing it ever puts where
/// someone else can see it is a notification). What it *does* put there turns
/// out to be a better signal than a raw percentage: it posts "Low Battery |
/// <phone>" / "N% of battery remaining" when the phone reports a low-battery
/// threshold event, **re-delivers it with the fresh percentage on every
/// subsequent battery packet while the phone is still low, and removes it the
/// moment the phone reports charging**. That is exactly the lifecycle Victor
/// asked for — blink until the phone is back on a charger — so presence of the
/// notification is the warning, and its body carries the number.
enum PhoneBatteryPolicy {

    /// Bundle id Soduto is filed under in the Notification Center database. It
    /// is stored **lowercased** there, unlike the bundle's own
    /// `CFBundleIdentifier` (`com.soduto.Soduto`) — compare case-insensitively.
    static let sodutoAppId = "com.soduto.soduto"

    /// Prefix of the `NSUserNotification.identifier` Soduto's battery service
    /// uses (`"<service id>.<device id>"`). This is what tells a low-battery
    /// notification apart from Soduto's pairing / file-transfer / SMS ones, all
    /// of which arrive under the same bundle id.
    static let batteryNotificationIdPrefix = "com.soduto.services.battery"

    /// Title marker, used only when a record carries no identifier at all.
    static let lowBatteryTitleMarker = "Low Battery"

    /// A notification nobody has refreshed for this long no longer says anything
    /// about *now*. Soduto clears it only when the phone reports charging — but a
    /// phone that goes flat and switches off stops sending packets altogether, so
    /// its last notification would otherwise sit in Notification Center and blink
    /// the tablet indefinitely. While the phone is genuinely connected and under
    /// 15% it drains fast enough that packets keep arriving well inside this
    /// window, so the cap costs nothing in the case that matters.
    static let staleAfter: TimeInterval = 90 * 60

    struct Reading: Equatable {
        let chargePct: Int
        /// When Soduto last (re-)delivered the notification.
        let updatedAt: Date
    }

    /// True for Soduto's battery notification specifically. Prefers the
    /// identifier (exact, locale-independent); the title is only consulted when
    /// the record has no identifier, since it is localized.
    static func isLowBatteryNotification(identifier: String?, title: String?) -> Bool {
        if let identifier, !identifier.isEmpty {
            return identifier.hasPrefix(batteryNotificationIdPrefix)
        }
        return title?.contains(lowBatteryTitleMarker) ?? false
    }

    /// Pull the charge out of `"13% of battery remaining"`. The format string is
    /// localized (`%d%%` plus translated words), so we look for the number
    /// attached to the percent sign rather than parsing the sentence.
    static func chargePercent(fromBody body: String?) -> Int? {
        guard let body, !body.isEmpty else { return nil }
        var digits = ""
        for ch in body {
            if ch.isNumber {
                digits.append(ch)
            } else if ch == "%", let value = Int(digits) {
                return (0...100).contains(value) ? value : nil
            } else {
                digits = ""
            }
        }
        return nil
    }

    /// Whether the tablet should be blinking right now.
    static func shouldWarn(_ reading: Reading?, now: Date, staleAfter: TimeInterval = staleAfter) -> Bool {
        guard let reading else { return false }
        guard (0...100).contains(reading.chargePct) else { return false }
        let age = now.timeIntervalSince(reading.updatedAt)
        // A clock that jumped backwards (or a record stamped a hair in the
        // future) must not read as stale — only real age counts.
        return age <= staleAfter
    }

    /// The `/ping` fields the tablet reads, as a fragment to splice into the
    /// hand-built ping JSON (leading comma included, no user-supplied strings —
    /// only a bool and an int, so nothing here can forge JSON).
    static func pingFields(for reading: Reading?, now: Date) -> String {
        let warn = shouldWarn(reading, now: now)
        let pct = warn ? (reading?.chargePct ?? -1) : -1
        return ",\"phoneBatteryLow\":\(warn),\"phoneBatteryPct\":\(pct)"
    }
}
