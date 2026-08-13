import Foundation
import CoreGraphics

class RHTimerMonitor {
    var onBreakEnded: (() -> Void)?

    private let windowChecker: () -> Bool
    private var wasVisible: Bool = false
    private var timer: Timer?

    /// Production init — uses real CGWindowList
    convenience init() {
        self.init(windowChecker: RHTimerMonitor.isTimerWindowVisible)
    }

    /// Testable init — inject custom window checker
    init(windowChecker: @escaping () -> Bool) {
        self.windowChecker = windowChecker
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkOnce()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        wasVisible = false
    }

    /// Exposed for testing; called by timer in production
    func checkOnce() {
        let isVisible = windowChecker()
        if wasVisible && !isVisible {
            onBreakEnded?()
        }
        wasVisible = isVisible
    }

    /// The ⏱️ is part of the string, not of the caller: the placeholder row
    /// ("⏱️ Resumed -") already carried it, so a live value without one made the
    /// item change shape the moment it started saying something.
    static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 3600 {
            return "⏱️ Resumed \(seconds / 60)m ago"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m > 0 ? "⏱️ Resumed \(h)h \(m)m ago" : "⏱️ Resumed \(h)h ago"
    }

    /// How overdue the next break is. The row is read at a glance, mid-sentence,
    /// so the *colour* has to carry it — by the time you've read "1h 52m" you
    /// have already spent the attention the glance was supposed to save.
    ///
    /// Thresholds are Victor's teaching rhythm: a section runs about an hour and
    /// a quarter, and past an hour and three quarters the room is gone.
    enum Urgency {
        case fresh      // still inside a normal section
        case due        // > 1h15m — a break belongs somewhere near here
        case overdue    // > 1h45m — well past it
    }

    static func urgency(_ seconds: Int) -> Urgency {
        if seconds > 105 * 60 { return .overdue }
        if seconds > 75 * 60 { return .due }
        return .fresh
    }

    private static func isTimerWindowVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let timerWindows = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == "Timer RH" }
        // The "Timers" countdown panel sits at layer 2147483631 — only onscreen when visible
        return timerWindows.contains { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 > 1_000_000 }
    }
}
