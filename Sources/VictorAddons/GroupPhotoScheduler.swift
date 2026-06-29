import Foundation

/// Fires `onTrigger` once a day, the moment local wall-clock time reaches
/// **13:00**. A 60s repeating `DispatchSourceTimer` polls the clock, and
/// exactly one tick lands inside the 13:00 minute. A per-day guard
/// (`lastFiredYMD`) makes the fire idempotent so it cannot double-trigger
/// within the same calendar day.
///
/// The caller decides whether to act on the trigger (e.g. only when the
/// training-assistant daemon is connected). A trigger missed because the app
/// was launched after 13:00 is intentionally *not* replayed.
final class GroupPhotoScheduler {
    /// Local hour the prompt fires at (13:00).
    static let triggerHour = 13

    var onTrigger: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.group-photo-scheduler", qos: .utility)
    /// `yyy-MM-dd` ordinal of the last day we already fired on. Lives only on
    /// `queue`, so reads/writes are sequential.
    private var lastFiredYMD: DateComponents?

    /// True when `date` falls inside the trigger minute (hour == 13, minute == 0)
    /// in the local calendar. Pure + side-effect free for unit testing.
    static func isTriggerMinute(at date: Date) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.hour, .minute], from: date)
        return comps.hour == triggerHour && comps.minute == 0
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        guard Self.isTriggerMinute(at: now) else { return }
        let cal = Calendar(identifier: .gregorian)
        let today = cal.dateComponents([.year, .month, .day], from: now)
        guard today != lastFiredYMD else { return }
        lastFiredYMD = today
        DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
    }
}
