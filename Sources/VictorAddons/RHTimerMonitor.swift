import Foundation
import CoreGraphics

class RHTimerMonitor {
    var onBreakEnded: (() -> Void)?
    var onPollResult: ((_ found: Bool) -> Void)?

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
        onPollResult?(isVisible)
        if wasVisible && !isVisible {
            onBreakEnded?()
        }
        wasVisible = isVisible
    }

    static func formatElapsed(_ seconds: Int) -> String {
        if seconds < 3600 {
            return "Resumed \(seconds / 60)m ago"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m > 0 ? "Resumed \(h)h \(m)m ago" : "Resumed \(h)h ago"
    }

    private static func isTimerWindowVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { w in
            (w[kCGWindowOwnerName as String] as? String) == "Timer RH" &&
            (w[kCGWindowName as String] as? String) == "Timers"
        }
    }
}
