import Foundation

/// Auto-on/auto-off schedule for live transcription.
///
/// Lock window = Mon–Fri 09:00–17:59 local time. Within the window the
/// transcription must be running and the user toggle is ignored. At 09:00
/// `ensureOn` fires; at 18:00 `forceOff` fires. While inside the window we
/// also heartbeat `ensureOn` every minute so a crashed Whisper process is
/// auto-recovered without user intervention.
///
/// Outside the window the user has full manual control. A manual ON persists
/// until the next 18:00 weekday (e.g. Friday 19:00 → Monday 18:00).
final class TranscriptionScheduler {
    var ensureOn: (() -> Void)?
    var forceOff: (() -> Void)?

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
        if lastLocked { fireEnsureOn() }
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
            fireEnsureOn()
        } else if !now && lastLocked {
            fireForceOff()
        } else if now {
            fireEnsureOn()
        }
    }

    private func fireEnsureOn() {
        DispatchQueue.main.async { [weak self] in self?.ensureOn?() }
    }

    private func fireForceOff() {
        DispatchQueue.main.async { [weak self] in self?.forceOff?() }
    }
}
