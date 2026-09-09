import ApplicationServices
import CoreGraphics
import Foundation

/// Aims a Cmd+scroll zoom at one terminal window and pins that window's frame
/// while its font size changes.
///
/// Two jobs, because on this gesture they are the same job:
///
/// **Aim.** The window the zoom belongs to is the one under the pointer
/// (`TerminalZoomTargeting`), not necessarily the one being typed in — but a
/// terminal applies Bigger/Smaller to whichever of *its* windows holds the
/// keyboard, so aiming means handing that window the keyboard for the length of
/// the gesture and handing it back afterwards.
///
/// **Pin.** Terminal.app and iTerm2 both read a font change as "keep the
/// character grid, resize the window": every Cmd+= grows the window, every Cmd+-
/// shrinks it. That is the wrong way round for a window that was put where it is
/// on purpose — tiled by ⌘⌃A, or sized to fill the projector — where only the
/// *text* should change size. So the frame observed when the gesture starts is
/// pinned and written back once the keystrokes settle; the terminal then reflows
/// its rows/columns into that frame instead of dragging the window around the
/// screen.
///
/// Everything goes through the in-process **Accessibility API** (`AXWindows`),
/// the same grant `TerminalTiler` and the event tap already rely on — no
/// Automation consent, no subprocess.
enum TerminalZoomSizeLock {

    /// Zoom steps closer together than this belong to one gesture: the frame is
    /// captured once, at the first step, so the window never chases the wheel.
    private static let gestureIdle: TimeInterval = 1.2
    /// How long after the last step to write the frame back. A single notch's
    /// resize lands well inside this; a burst of notches keeps pushing it out.
    private static let restoreDelay: TimeInterval = 0.08
    /// A second, later write, for a terminal that relayouts lazily.
    private static let settleDelay: TimeInterval = 0.35
    /// When to give the keyboard back. After `settleDelay`, so the pinning is
    /// finished before the window stops being the one the app is aiming at.
    private static let focusReturnDelay: TimeInterval = 0.6

    /// All state is confined to this serial queue: the tap thread enters it with
    /// `sync` (it must capture the frame *before* the keystroke lands), the delayed
    /// writes with `asyncAfter`.
    private static let queue = DispatchQueue(label: "ro.victorrentea.addons.terminal-zoom-lock")

    private static var pinnedPid: pid_t?
    private static var pinnedWindow: AXUIElement?
    private static var pinnedFrame: CGRect?
    private static var settledFrame: CGRect?
    private static var focusToReturn: AXUIElement?
    private static var lastStep: Date = .distantPast
    private static var pendingRestore: DispatchWorkItem?
    private static var pendingSettle: DispatchWorkItem?
    private static var pendingFocusReturn: DispatchWorkItem?

    /// Call on the event-tap thread immediately **before** posting the zoom
    /// keystroke: the keystroke has to find the target window already holding the
    /// keyboard, and the frame captured here has to still be the pre-zoom one.
    ///
    /// - Returns: which of the two directions the target window may still be
    ///   taken in, measured on the window itself (`TerminalFontSize.cell`) rather
    ///   than counted, so a window that was already zoomed before this app
    ///   started — or with the plain Cmd+= this gesture does not manage — is
    ///   judged on what it actually looks like. The read is one AX round trip per
    ///   notch, on a thread that already makes several; a burst scrolled faster
    ///   than the terminal redraws can therefore overshoot a bound by a step,
    ///   and the next notch stops it.
    @discardableResult
    static func beforeZoomStep(pid: pid_t, window: AXUIElement) -> TerminalZoomLimitsPolicy.Allowed {
        queue.sync {
            let now = Date()
            let sameWindow = pinnedWindow.map { CFEqual($0, window) } ?? false
            // A new gesture is either a fresh one after a pause, or the pointer
            // moving onto a different terminal window mid-scroll — the second one
            // has to re-aim, so it cannot be folded into the first.
            if now.timeIntervalSince(lastStep) > gestureIdle || !sameWindow {
                pin(pid: pid, window: window, continuing: sameWindow)
            }
            lastStep = now
            let limits = TerminalZoomLimitsPolicy.allowed(cellHeight: TerminalFontSize.cell(of: window)?.height)
            guard pinnedWindow != nil, pinnedFrame != nil else { return limits }
            scheduleWriteBack()
            scheduleFocusReturn()
            return limits
        }
    }

    // MARK: - Gesture start

    private static func pin(pid: pid_t, window: AXUIElement, continuing: Bool) {
        borrowFocus(pid: pid, to: window)
        guard let observed = AXWindows.frame(of: window) else {
            pinnedPid = nil; pinnedWindow = nil; pinnedFrame = nil; settledFrame = nil
            return
        }
        pinnedFrame = TerminalZoomSizeLockPolicy.frameToPin(
            observed: observed,
            pinned: continuing ? pinnedFrame : nil,
            settled: continuing ? settledFrame : nil
        )
        pinnedPid = pid
        pinnedWindow = window
        settledFrame = nil
    }

    // MARK: - Borrowing the keyboard

    /// Hand `window` the keyboard inside its own application, remembering which
    /// window had it so the borrow can be given back.
    ///
    /// There is no way around the borrow. Measured on Terminal.app on 2026-09-07,
    /// with the app **inactive**, all three of the obvious alternatives report
    /// success and change nothing: keys posted straight into the process
    /// (`CGEventPostToPid`), an Accessibility press of View ▸ Bigger, and setting
    /// `AXFocused` on the window itself (`rc = 0`, and the app's focused window
    /// afterwards is still the old one). An inactive application has no key
    /// window, so a font command has nothing to apply to. With the app **active**
    /// the same `AXFocused` set works, and Cmd+= then zooms exactly the window it
    /// was pointed at — which is why the pointer only ever retargets *within* the
    /// active terminal (`TerminalZoomTargetPolicy.choose`), and why this is a
    /// focus change rather than a way of avoiding one.
    private static func borrowFocus(pid: pid_t, to window: AXUIElement) {
        guard let current = AXWindows.focusedWindow(pid: pid), !CFEqual(current, window) else { return }
        // Only the *first* borrow of a chain is remembered: dragging the pointer
        // across three terminals should give the keyboard back to where it started,
        // not to the second terminal it passed over.
        if focusToReturn == nil { focusToReturn = current }
        AXWindows.focus(window)
    }

    private static func scheduleFocusReturn() {
        guard focusToReturn != nil else { return }
        pendingFocusReturn?.cancel()
        let item = DispatchWorkItem { returnFocus() }
        pendingFocusReturn = item
        queue.asyncAfter(deadline: .now() + focusReturnDelay, execute: item)
    }

    private static func returnFocus() {
        guard let owed = focusToReturn else { return }
        focusToReturn = nil
        // If something else has taken the keyboard in the meantime — a click in
        // another window, a different app — the borrow is stale, and giving it
        // back would be us stealing focus, which is the one thing this gesture
        // must not do.
        guard let pid = pinnedPid, let target = pinnedWindow,
              let current = AXWindows.focusedWindow(pid: pid), CFEqual(current, target) else { return }
        AXWindows.focus(owed)
    }

    // MARK: - Write-back

    private static func scheduleWriteBack() {
        pendingRestore?.cancel()
        pendingSettle?.cancel()
        let restore = DispatchWorkItem { writeBack() }
        let settle = DispatchWorkItem { writeBack() }
        pendingRestore = restore
        pendingSettle = settle
        queue.asyncAfter(deadline: .now() + restoreDelay, execute: restore)
        queue.asyncAfter(deadline: .now() + settleDelay, execute: settle)
    }

    private static func writeBack() {
        guard let win = pinnedWindow, let target = pinnedFrame else { return }
        AXWindows.setFrame(win, target)
        // Remember what the window actually measured afterwards: the terminal snaps
        // the size down to a whole number of character cells, so this is usually a
        // few points off `target`. Recognising it next time is what keeps that
        // snapping from nibbling the window smaller gesture after gesture.
        settledFrame = AXWindows.frame(of: win)
    }
}

/// Pure half of `TerminalZoomSizeLock`: which frame a new zoom gesture should pin.
enum TerminalZoomSizeLockPolicy {

    /// AX gives back the doubles it was handed, so this only absorbs float noise.
    static let epsilon: CGFloat = 0.5

    /// - Parameters:
    ///   - observed: the window's frame right now, at the start of a gesture.
    ///   - pinned: the frame the previous gesture pinned (`nil` if none, or if the
    ///     target window has changed since).
    ///   - settled: what the window measured after that gesture's last write-back.
    /// - Returns: the frame to hold the window at for this gesture.
    ///
    /// The window still measuring exactly what we left it at means nobody moved or
    /// resized it by hand, so the original `pinned` frame stays authoritative — the
    /// terminal's rounding-down to whole character cells is undone rather than
    /// compounded. Anything else (first gesture, a different window, a manual drag
    /// or resize) makes what the user sees now the new truth.
    static func frameToPin(observed: CGRect, pinned: CGRect?, settled: CGRect?) -> CGRect {
        guard let pinned, let settled, approxEqual(settled, observed) else { return observed }
        return pinned
    }

    static func approxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < epsilon && abs(a.origin.y - b.origin.y) < epsilon
            && abs(a.width - b.width) < epsilon && abs(a.height - b.height) < epsilon
    }
}
