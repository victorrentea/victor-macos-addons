import Foundation
import CoreGraphics

/// Pure, testable countdown logic for the Break timer overlay.
/// No UIKit/AppKit — formatting and finish-time math only.
enum BreakTimerModel {

    /// The centered "big" frame for the idle/fullscreen mode: the largest rect of
    /// the given `aspect` (width / height) that fits within `fraction` of
    /// `screenFrame` on BOTH axes, centered in `screenFrame`. Used when the user
    /// has been fully idle — the timer grows to fill most of the screen (a large
    /// countdown on black) without covering the whole desktop. Aspect is
    /// preserved, so the result never distorts the digits; height-constrained
    /// screens (tall monitors) fit by height instead of width.
    static func enlargedFrame(in screenFrame: CGRect, aspect: CGFloat, fraction: CGFloat) -> CGRect {
        let f = max(0, fraction)
        let a = aspect > 0 ? aspect : 1
        let availW = screenFrame.width * f
        let availH = screenFrame.height * f
        var w = availW
        var h = w / a
        if h > availH { h = availH; w = h * a }   // too tall for the band → fit by height
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
