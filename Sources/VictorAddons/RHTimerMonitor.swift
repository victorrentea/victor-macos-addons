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
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

    private(set) static var lastWindowCount: Int = 0
    private(set) static var lastTimerRHCount: Int = 0
    private(set) static var lastTimerNames: [String] = []

    private static func isTimerWindowVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            lastWindowCount = -1
            lastTimerRHCount = -1
            return false
        }
        lastWindowCount = windows.count
        let timerWindows = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == "Timer RH" }
        lastTimerRHCount = timerWindows.count
        lastTimerNames = timerWindows.compactMap { ($0[kCGWindowLayer as String] as? NSNumber).map { "L\($0)" } }
        // The "Timers" countdown panel sits at layer 2147483631 — only onscreen when visible
        return timerWindows.contains { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 > 1_000_000 }
    }
}
