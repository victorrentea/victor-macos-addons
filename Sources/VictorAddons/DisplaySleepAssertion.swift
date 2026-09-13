import Foundation
import IOKit.pwr_mgt

/// One `kIOPMAssertionTypePreventUserIdleDisplaySleep` assertion, held or not.
///
/// Extracted from `BreakTimerOverlay` (which had the only copy) on 13 Sep 2026,
/// when 🏠 Home Wi-Fi became the second thing in this app that needs to stop the
/// display idling. Two hand-rolled `IOPMAssertionCreateWithName` pairs are two
/// places to leak an assertion from, and a leaked one keeps the screen lit until
/// the process dies — so there is one implementation and both features hold an
/// instance of it.
///
/// **What this assertion does and does not do**, because it is the whole
/// contract of 🏠 and it surprises people:
///
/// - It stops the *display* from idling. No display idle means macOS never
///   starts the screen saver, and "require password after the screen saver
///   starts" therefore never fires. That is the entire mechanism by which the
///   Mac stops locking itself — nothing here touches the lock screen.
/// - In practice the Mac also stays fully awake, because `powerd` holds its own
///   "Prevent sleep while display is on" system assertion for as long as the
///   display is up. That is a consequence, not something this asks for.
/// - It does **not** defeat a lock Victor asks for. ⌃⌘Q, a hot corner, the
///   lid closing, `pmset displaysleepnow` and Lock Screen in the  menu all
///   still work exactly as before: an assertion vetoes the *idle timer*, never
///   an explicit request. Being able to lock the machine on purpose at home is
///   the point, not a gap.
///
/// **Nothing can leak it past the process.** IOPM assertions are owned by the
/// pid that created them and the kernel drops them when it exits — including on
/// the `pkill -f "Victor Addons"` half of the standard rebuild loop, which runs
/// no terminate handler. This is the one thing it does better than `LidAwake`'s
/// kernel `SleepDisabled` flag, which deliberately survives to the next reboot.
/// Verify either way with `pmset -g assertions`.
final class DisplaySleepAssertion {

    /// Shown verbatim in `pmset -g assertions`, so make it findable.
    private let name: String
    /// Logged on each edge, or nil to hold silently (the break timer's fullscreen
    /// comes and goes with idleness and does not deserve a log line each way).
    private let logPrefix: String?

    private var id: IOPMAssertionID = 0
    private(set) var isHeld = false

    init(name: String, logPrefix: String? = nil) {
        self.name = name
        self.logPrefix = logPrefix
    }

    /// Idempotent in both directions — only the real edge touches IOKit, so a
    /// caller on a 60 s clock can simply restate what it wants every tick.
    /// Returns whether the assertion is held afterwards.
    @discardableResult
    func hold(_ wanted: Bool, reason: @autoclosure () -> String = "") -> Bool {
        if wanted {
            guard !isHeld else { return true }
            var newID: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &newID)
            guard ok == kIOReturnSuccess else {
                if let logPrefix { overlayError("\(logPrefix) could not take the display assertion (IOKit \(ok))") }
                return false
            }
            id = newID
            isHeld = true
            if let logPrefix {
                let why = reason()
                overlayInfo("\(logPrefix) holding the display awake\(why.isEmpty ? "" : " — \(why)")")
            }
        } else {
            guard isHeld else { return false }
            IOPMAssertionRelease(id)
            id = 0
            isHeld = false
            if let logPrefix {
                let why = reason()
                overlayInfo("\(logPrefix) released the display assertion\(why.isEmpty ? "" : " — \(why)")")
            }
        }
        return isHeld
    }
}
