import AppKit
import CoreGraphics
import Darwin

/// 🔒 The safety net under the hands-off frame: it watches for **synthetic**
/// mouse and keyboard events and raises the locks by itself, whether or not the
/// agent that posted them remembered to announce anything.
///
/// Why it exists, when `docs/hands-off.md` argued the opposite ("announce, not
/// auto-detect"): on 10–11 Sep 2026 both codex and Claude drove Victor's mouse
/// while he was working and **he saw no lock at all** — the HTTP door had been
/// called exactly twice in its life, both times by the session that built it.
/// A warning that depends on the offender remembering to warn is not a warning,
/// it is a good intention. The announce path stays (it says *who* and *what*,
/// which a tap cannot know); this one guarantees the floor.
///
/// The old objection — "a tap would fire for codex too, and codex does not
/// interrupt anything" — no longer holds as an objection: if codex posts events
/// that land in Victor's session, they *are* his mouse moving. The rule is now
/// simply "something that is not a human hand is driving", and codex's own
/// background path (`@oai/sky`) posts nothing here, so it stays silent by
/// itself rather than by exemption.
///
/// **How synthetic is told from real:** every `CGEvent` carries the pid of the
/// process that posted it in `.eventSourceUnixProcessID`. Hardware events come
/// out of the HID system with **0**. Anything non-zero was typed by software.
///
/// **The allowlist is the whole risk.** This Mac is full of software that posts
/// events on Victor's behalf and at his request — Wispr Flow types his dictation,
/// Walkie Talkie and this very app paste snippets and stamp Returns. Those are
/// his hands by proxy, not an agent taking over, and raising locks for them would
/// train him to ignore locks. Everything else is assumed hostile.
@MainActor
final class SyntheticInputWatch {

    /// Software that types *for* Victor, at the moment he asks it to. Matched
    /// case-insensitively against the posting process's name, as a substring, so
    /// helper processes ("Wispr Flow Helper") are covered by their parent's name.
    static let allowlist = [
        "wispr",            // his dictation — types into whatever is focused
        "walkie talkie",    // the relay's own paste + shutter Return
        "victor addons",    // us: snippet paste, ⌘⌃ launchers, BackButtonEnter
        "karabiner",
        "raycast",
        "alfred",
        "logi",             // Logi Options+ button remaps
        "hammerspoon",
        "keyboard maestro"
    ]

    /// How long the locks stay up after the last synthetic event. Long enough to
    /// bridge the gaps inside one GUI dance (a menu opens, a sheet animates, the
    /// agent thinks for a second) so the frame does not strobe on and off; short
    /// enough that "the locks are gone" still means "it is yours again".
    private let quietWindow: TimeInterval = 5

    /// Only ever raised for at most this long without a new synthetic event —
    /// the overlay's own watchdog is the outer backstop, this is the inner one.
    private let autoTTL: TimeInterval = 30

    /// Written on the tap thread, read on main. A lock rather than an actor hop
    /// per event: mouse-moved arrives ~100×/s while an agent drags something, and
    /// the tap callback is the one place on this Mac where being slow is felt as
    /// lag under Victor's own hand.
    final class LastSynthetic: @unchecked Sendable {
        private let lock = NSLock()
        private var at: Date?
        private var pid: pid_t = 0

        func note(pid: pid_t) {
            lock.lock(); self.at = Date(); self.pid = pid; lock.unlock()
        }

        func snapshot() -> (at: Date?, pid: pid_t) {
            lock.lock(); defer { lock.unlock() }
            return (at, pid)
        }
    }

    private weak var overlay: HandsOffOverlay?
    private var tapPort: CFMachPort?
    private var quietTimer: Timer?
    nonisolated let lastSynthetic = LastSynthetic()

    init(overlay: HandsOffOverlay) {
        self.overlay = overlay
    }

    func start() {
        let mask: CGEventMask =
            CGEventMask(1 << CGEventType.mouseMoved.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) |
            CGEventMask(1 << CGEventType.rightMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.scrollWheel.rawValue)

        // `.listenOnly`: this must never be able to swallow or delay one of
        // Victor's own events. A warning system that can drop a keystroke is a
        // worse bug than the thing it warns about.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .tailAppendEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: syntheticTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            overlayError("SyntheticInputWatch: could not create tap — check Accessibility")
            return
        }
        tapPort = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "SyntheticInputWatch"
        thread.start()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
        overlayInfo("SyntheticInputWatch: armed")
    }

    /// Re-arm a tap the system disabled for taking too long. Listen-only taps
    /// are rarely killed, but a Mac under a heavy build is exactly when an agent
    /// is also driving it.
    private func reenable() {
        guard let port = tapPort else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Called from the C tap callback, on the tap's thread.
    nonisolated func noteEvent(_ event: CGEvent, type: CGEventType) {
        if type.rawValue == 0xFFFF_FFFE { // kCGEventTapDisabledByTimeout
            // Hop to main rather than re-enabling here: the port is main-actor
            // state, and a tap that is already timing out is in no hurry.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.reenable() }
            }
            return
        }
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid != 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
        lastSynthetic.note(pid: pid)
    }

    /// One check a second, on main, where AppKit may be touched: resolving a pid
    /// to a name and raising a panel are both main-thread work, and doing them
    /// from the tap callback is how you deadlock a machine that is already
    /// having its mouse taken.
    private func tick() {
        let (at, pid) = lastSynthetic.snapshot()
        guard let overlay else { return }
        guard let at else { return }
        let quiet = Date().timeIntervalSince(at)

        if quiet < quietWindow {
            let name = Self.processName(for: pid)
            guard !Self.isAllowlisted(name) else { return }
            if overlay.isAutoRaised {
                overlay.refreshAuto(agent: name, ttl: autoTTL)
            } else if !overlay.isActive {
                overlay.beginAuto(agent: name, ttl: autoTTL)
                overlayInfo("SyntheticInputWatch: \(name) (pid \(pid)) is posting input — locks raised")
            }
            // An agent that *did* announce itself keeps its own label; nothing to do.
        } else if overlay.isAutoRaised {
            // Silent release: an auto-raised frame goes up and down in bursts as
            // a script works, and a Tink per burst would be its own annoyance.
            // The announced path keeps the chime, where release is one event.
            overlay.end(silent: true)
        }
    }

    static func isAllowlisted(_ name: String) -> Bool {
        let lower = name.lowercased()
        return allowlist.contains { lower.contains($0) }
    }

    /// Name of the process behind a pid. `NSRunningApplication` first (that is
    /// the name Victor would recognise from the Dock), falling back to the
    /// executable name for the faceless helpers agents actually run as.
    private static func processName(for pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if !path.isEmpty { return (path as NSString).lastPathComponent }
        }
        return "pid \(pid)"
    }
}

private func syntheticTapCallback(proxy: CGEventTapProxy,
                                  type: CGEventType,
                                  event: CGEvent,
                                  userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let watch = Unmanaged<SyntheticInputWatch>.fromOpaque(userInfo).takeUnretainedValue()
        watch.noteEvent(event, type: type)
    }
    return Unmanaged.passUnretained(event)
}
