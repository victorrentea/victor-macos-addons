import Foundation
import CoreGraphics

/// Pure, testable countdown logic for the Break timer overlay.
/// No UIKit/AppKit — formatting and finish-time math only.
enum BreakTimerModel {

    /// The frame the timer fills in the fullscreen "break screen" mode: a rect
    /// covering `fraction` of `screenFrame` on BOTH axes, centered. Unlike the old
    /// aspect-preserving enlarge, this deliberately does NOT keep the digit aspect —
    /// the panel becomes a full black, desktop-like fill (the view re-centers and
    /// scales the digits inside), so with `fraction` 1.0 it covers the entire
    /// screen (menu bar included) and the retina reads like a pause/lock screen.
    /// A non-zero screen origin (a secondary display) is honored in the centering.
    static func fullscreenFrame(in screenFrame: CGRect, fraction: CGFloat = 1.0) -> CGRect {
        let f = min(1, max(0, fraction))
        let w = screenFrame.width * f
        let h = screenFrame.height * f
        let x = screenFrame.minX + (screenFrame.width - w) / 2
        let y = screenFrame.minY + (screenFrame.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Format remaining seconds as `MM:SS`. Minutes are NOT capped at 59 — one
    /// hour shows `60:00` to keep the two-group "watch" look. Negative values
    /// clamp to `00:00`.
    static func format(remaining seconds: Int) -> String {
        let total = max(0, seconds)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// The wall-clock moment the countdown reaches zero: `now + remaining`.
    static func finishDate(now: Date, remaining seconds: Int) -> Date {
        now.addingTimeInterval(TimeInterval(max(0, seconds)))
    }

    /// The finish time rendered as 24-hour `HH:mm TZ` in the given timezone,
    /// e.g. `17:10 EEST` or `16:10 CET`. No AM/PM.
    static func finishLabel(now: Date, remaining seconds: Int, timeZone: TimeZone) -> String {
        let finish = finishDate(now: now, remaining: seconds)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "HH:mm"
        let abbr = timeZone.abbreviation(for: finish) ?? ""
        return "\(df.string(from: finish)) \(abbr)"
    }
}
