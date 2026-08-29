import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Tracks whether the Mac's screen is locked, so `/ping` can tell the tablet to
/// go dark.
///
/// The tablet sits on the desk lit up all day, which is exactly what you want in
/// a room full of people and exactly what you don't want at night: a locked
/// laptop in a hotel room leaves the soundboard glowing at full brightness until
/// morning. The lock is the one signal that means "nobody is looking at either
/// screen right now" without needing anything on the tablet's side to guess.
///
/// **The lock, and only the lock.** Closing the lid or shutting the Mac down is
/// deliberately *not* mirrored: the tablet reads a dropped Mac link as "no news",
/// not as "go to sleep" (see `MacLink.setConnected` on the Android side), because
/// the Mac routinely disappears for network reasons — a filtered venue hotspot,
/// a Wi-Fi handover — while both devices are very much in use. Going dark on
/// silence would blank the soundboard mid-workshop.
///
/// macOS publishes the lock as two *distributed* notifications
/// (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`) — they cross
/// process boundaries, unlike `NSWorkspace`'s, and they are the only
/// non-deprecated public way to hear about it. They are edges, so the current
/// state is seeded from the session dictionary at startup: the app is launched by
/// a LaunchAgent at login and can also be restarted at any time, including while
/// the screen happens to be locked.
final class ScreenLockMonitor {

    /// Fired on the main thread whenever the lock state changes.
    var onChange: ((Bool) -> Void)?

    private let lock = NSLock()
    private var _isLocked = false
    private var _simulated: Bool?
    private var _simulatedUntil = Date.distantPast

    /// How long `/test/screen-lock/simulate/<0|1>` holds its answer. Long enough
    /// to walk over to the tablet and watch it fade, short enough that a forgotten
    /// simulation cannot outlive the session.
    static let simulationWindow: TimeInterval = 10 * 60

    /// What the tablet is told right now. A live simulation wins.
    var isLocked: Bool {
        lock.lock(); defer { lock.unlock() }
        if let simulated = _simulated, Date() < _simulatedUntil { return simulated }
        return _isLocked
    }

    func start() {
        seedFromSession()
        #if canImport(AppKit)
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.set(locked: true) }
        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.set(locked: false) }
        #endif
    }

    /// Preview hook: pretend the screen is locked (or unlocked) for
    /// `simulationWindow`, so the tablet's standby can be seen without actually
    /// locking the Mac — which would, of course, hide the thing you are watching.
    func simulate(locked: Bool) {
        lock.lock()
        _simulated = locked
        _simulatedUntil = Date().addingTimeInterval(Self.simulationWindow)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onChange?(locked) }
    }

    /// Drop a running simulation and fall back to the real lock state.
    func clearSimulation() {
        lock.lock()
        _simulated = nil
        _simulatedUntil = .distantPast
        let real = _isLocked
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onChange?(real) }
    }

    var diagnosticsJSON: String {
        lock.lock()
        let real = _isLocked
        let simulating = _simulated != nil && Date() < _simulatedUntil
        let simulated = _simulated
        lock.unlock()
        let effective = simulating ? (simulated ?? real) : real
        return "{\"locked\":\(effective),\"real\":\(real),\"simulating\":\(simulating)}"
    }

    /// The `/ping` field the tablet reads (leading comma included; a bare bool,
    /// so nothing here can forge JSON).
    var pingField: String { ",\"macScreenLocked\":\(isLocked)" }

    private func set(locked: Bool) {
        lock.lock()
        let changed = _isLocked != locked
        _isLocked = locked
        // A real lock/unlock is the user at the keyboard — it outranks and ends
        // any simulation still running, rather than leaving the tablet obeying a
        // test hook nobody remembers arming.
        _simulated = nil
        _simulatedUntil = .distantPast
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(locked) }
    }

    /// Current state at startup, from the login session dictionary — the
    /// notifications are edges and we may well have been launched (or restarted)
    /// while the screen was already locked. Absent key = not locked.
    private func seedFromSession() {
        #if canImport(AppKit)
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let locked = (session["CGSSessionScreenIsLocked"] as? Bool)
            ?? ((session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false)
        lock.lock(); _isLocked = locked; lock.unlock()
        #endif
    }
}
