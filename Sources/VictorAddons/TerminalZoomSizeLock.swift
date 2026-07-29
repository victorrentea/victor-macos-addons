import ApplicationServices
import CoreGraphics
import Foundation

/// Pins a terminal window's frame while Cmd+scroll changes its font size.
///
/// Terminal.app and iTerm2 both read a font change as "keep the character grid,
/// resize the window": every Cmd+= grows the window, every Cmd+- shrinks it. That
/// is the wrong way round for a window that was put where it is on purpose — tiled
/// by ⌘⌃A, or sized to fill the projector — where only the *text* should change
/// size. So the frame observed when the zoom gesture starts is pinned and written
/// back once the keystrokes settle; the terminal then reflows its rows/columns into
/// that frame instead of dragging the window around the screen.
///
/// The frame is read/written through the in-process **Accessibility API**, the same
/// grant `TerminalTiler` and the event tap already rely on — no Automation consent,
/// no subprocess.
enum TerminalZoomSizeLock {

    /// Zoom steps closer together than this belong to one gesture: the frame is
    /// captured once, at the first step, so the window never chases the wheel.
    private static let gestureIdle: TimeInterval = 1.2
    /// How long after the last step to write the frame back. A single notch's
    /// resize lands well inside this; a burst of notches keeps pushing it out.
    private static let restoreDelay: TimeInterval = 0.08
    /// A second, later write, for a terminal that relayouts lazily.
    private static let settleDelay: TimeInterval = 0.35
    /// AX round trips happen on the event-tap thread — cap them so a wedged
    /// terminal can never stall the tap into a system timeout.
    private static let axTimeout: Float = 0.1

    /// All state is confined to this serial queue: the tap thread enters it with
    /// `sync` (it must capture the frame *before* the keystroke lands), the delayed
    /// writes with `asyncAfter`.
    private static let queue = DispatchQueue(label: "ro.victorrentea.addons.terminal-zoom-lock")

    private static var appElements: [pid_t: AXUIElement] = [:]
    private static var pinnedWindow: AXUIElement?
    private static var pinnedFrame: CGRect?
    private static var settledFrame: CGRect?
    private static var lastStep: Date = .distantPast
    private static var pendingRestore: DispatchWorkItem?
    private static var pendingSettle: DispatchWorkItem?

    /// Call on the event-tap thread immediately **before** posting the zoom
    /// keystroke, so the frame captured is still the pre-zoom one.
    static func beforeZoomStep(pid: pid_t) {
        queue.sync {
            let now = Date()
            if now.timeIntervalSince(lastStep) > gestureIdle {
                pin(pid: pid)
            }
            lastStep = now
            guard pinnedWindow != nil, pinnedFrame != nil else { return }
            scheduleWriteBack()
        }
    }

    // MARK: - Gesture start

    private static func pin(pid: pid_t) {
        guard let win = focusedWindow(pid: pid), let observed = frame(of: win) else {
            pinnedWindow = nil; pinnedFrame = nil; settledFrame = nil
            return
        }
        let same = pinnedWindow.map { CFEqual($0, win) } ?? false
        pinnedFrame = TerminalZoomSizeLockPolicy.frameToPin(
            observed: observed,
            pinned: same ? pinnedFrame : nil,
            settled: same ? settledFrame : nil
        )
        pinnedWindow = win
        settledFrame = nil
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
        setFrame(win, target)
        // Remember what the window actually measured afterwards: the terminal snaps
        // the size down to a whole number of character cells, so this is usually a
        // few points off `target`. Recognising it next time is what keeps that
        // snapping from nibbling the window smaller gesture after gesture.
        settledFrame = frame(of: win)
    }

    // MARK: - Accessibility plumbing

    private static func appElement(pid: pid_t) -> AXUIElement {
        if let el = appElements[pid] { return el }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, axTimeout)
        appElements[pid] = el
        return el
    }

    private static func focusedWindow(pid: pid_t) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid: pid),
                                            kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func frame(of win: AXUIElement) -> CGRect? {
        guard let pos = axValue(of: win, kAXPositionAttribute, type: .cgPoint, as: CGPoint.self),
              let size = axValue(of: win, kAXSizeAttribute, type: .cgSize, as: CGSize.self) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    private static func setFrame(_ win: AXUIElement, _ rect: CGRect) {
        var size = rect.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, value)
        }
        // Position after size: a window pinned near a screen edge can be nudged by
        // the resize, and the origin is the half we can restore exactly.
        var origin = rect.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, value)
        }
    }

    private static func axValue<T>(of el: AXUIElement, _ attr: String,
                                   type: AXValueType, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(value as! AXValue, type, out) else { return nil }
        return out.pointee
    }
}

/// Pure half of `TerminalZoomSizeLock`: which frame a new zoom gesture should pin.
enum TerminalZoomSizeLockPolicy {

    /// AX gives back the doubles it was handed, so this only absorbs float noise.
    static let epsilon: CGFloat = 0.5

    /// - Parameters:
    ///   - observed: the window's frame right now, at the start of a gesture.
    ///   - pinned: the frame the previous gesture pinned (`nil` if none, or if the
    ///     focused window has changed since).
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
