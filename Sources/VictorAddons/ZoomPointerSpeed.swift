import CoreGraphics
import Foundation

/// 🔎 Slows the mouse down by the zoom factor while `ShareZoom` magnifies, so a small
/// move on the table is a small move on the glass. Without it, at 4× the drawn cursor
/// crossed the picture four times as fast and the slice ran off left and right under
/// the hand (Victor, 2026-10-27: *"la o mișcare mică pe masă îmi fuge foarte rău"*).
///
/// **How: every move is taken back to 1/factor of itself.** An HID tap sees each move
/// after WindowServer has already put the cursor at its new place, accelerated; the
/// cursor is warped to `last + (new − last) / factor` instead, and the event is told
/// the same. The acceleration curve Victor is used to stays, only scaled. `pos` keeps
/// the fractions a warp to whole points would lose, or slow moves would never add up.
///
/// **What did not work** (2026-10-27): raising the M650's `HIDPointerResolution`
/// through a monitor HID client. Every set returned true and the mouse did not slow
/// at all. Decoupling the mouse (`ZoomLensCursorFence`) was not tried here: its
/// deltas are raw, with no curve, and no constant over them ever felt right.
///
/// **The tap is enabled only while zoomed**, from `ShareZoom.follow`'s 120 Hz tick.
final class ZoomPointerSpeed {

    private var tapPort: CFMachPort?
    /// Shared between main (`follow`) and the tap thread (every move): hence the lock.
    private let lock = NSLock()
    private var factor: CGFloat = 1
    /// Where the cursor was put last, with its fractions; nil until the first move.
    private var pos: CGPoint?

    init() { createTap() }

    /// Main thread, every zoom tick.
    func follow(factor: CGFloat) {
        let k = max(factor, 1)
        lock.lock()
        let was = self.factor
        self.factor = k
        if k == 1 { pos = nil }
        lock.unlock()
        guard let port = tapPort, (was > 1) != (k > 1) else { return }
        CGEvent.tapEnable(tap: port, enable: k > 1)
        overlayInfo("🔎 pointer slowed by the zoom factor: \(k > 1 ? "on" : "off")")
    }

    func restore() { follow(factor: 1) }

    private func createTap() {
        let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let me = Unmanaged<ZoomPointerSpeed>.fromOpaque(userInfo!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            overlayError("ZoomPointerSpeed: could not create HID tap — check Accessibility")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        tapPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "ZoomPointerSpeed"
        thread.start()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock(); defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if factor > 1, let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard factor > 1 else { return Unmanaged.passUnretained(event) }
        let now = event.location
        // The first move, or a jump no hand makes in one event (a warp by someone
        // else, a display change): follow it rather than scale it.
        guard let last = pos, hypot(now.x - last.x, now.y - last.y) < 400 else {
            pos = now
            return Unmanaged.passUnretained(event)
        }
        let next = CGPoint(x: last.x + (now.x - last.x) / factor, y: last.y + (now.y - last.y) / factor)
        pos = next
        CGWarpMouseCursorPosition(next)
        // A warp mutes the mouse for 0.25 s; re-associating lifts that at once.
        CGAssociateMouseAndMouseCursorPosition(1)
        event.location = next
        event.setDoubleValueField(.mouseEventDeltaX, value: event.getDoubleValueField(.mouseEventDeltaX) / Double(factor))
        event.setDoubleValueField(.mouseEventDeltaY, value: event.getDoubleValueField(.mouseEventDeltaY) / Double(factor))
        return Unmanaged.passUnretained(event)
    }
}
