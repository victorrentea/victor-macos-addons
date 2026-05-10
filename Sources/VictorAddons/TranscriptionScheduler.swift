import Foundation

/// Workday window scheduler.
///
/// Lock window = Mon–Fri 09:00–17:59 local time. Fires three distinct
/// callbacks so the state machine can apply the correct transition:
///
///   - `onEnterWindow` — at the 09:00 boundary (window just became active)
///   - `onExitWindow`  — at the 18:00 boundary (window just deactivated)
///   - `onHeartbeat`   — every minute *while* the window is active
final class TranscriptionScheduler {
    var onEnterWindow: (() -> Void)?
    var onExitWindow: (() -> Void)?
    var onHeartbeat: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.transcription-scheduler", qos: .utility)
    private var lastLocked: Bool = false

    static func isLockedOn(at date: Date = Date()) -> Bool {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.weekday, .hour], from: date)
        // Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat. Mon–Fri = 2…6.
        guard let weekday = comps.weekday, (2...6).contains(weekday) else { return false }
        let hour = comps.hour ?? 0
        return (9..<18).contains(hour)
    }

    func start() {
        lastLocked = Self.isLockedOn()
        if lastLocked {
            DispatchQueue.main.async { [weak self] in self?.onEnterWindow?() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Self.isLockedOn()
        defer { lastLocked = now }
        if now && !lastLocked {
            fire(\.onEnterWindow)
        } else if !now && lastLocked {
            fire(\.onExitWindow)
        } else if now {
            fire(\.onHeartbeat)
        }
    }

    private func fire(_ kp: KeyPath<TranscriptionScheduler, (() -> Void)?>) {
        let cb = self[keyPath: kp]
        DispatchQueue.main.async { cb?() }
    }
}
