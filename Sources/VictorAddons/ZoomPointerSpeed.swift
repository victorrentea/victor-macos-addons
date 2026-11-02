import CoreGraphics
import Foundation

/// 🔎 Slows the mouse down in proportion to the zoom while `ShareZoom` magnifies, so a
/// move on the table covers the same stretch of glass at every factor. Without it, at 4× the drawn cursor
/// crossed the picture four times as fast and the slice ran off left and right under
/// the hand (Victor, 2026-10-27: *"la o mișcare mică pe masă îmi fuge foarte rău"*).
///
/// **How: every move is scaled down by `ShareZoomPolicy.pointerSlowdown`.** An HID tap
/// sees each move after WindowServer has already put the cursor at its new place; the
/// cursor is warped to `last + delta / slowdown` instead (the event's own delta,
/// already accelerated), and the event is told the same. The acceleration curve Victor
/// is used to stays, only scaled. `pos` keeps the fractions a warp to whole points
/// would lose, or slow moves would never add up.
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
    /// `ShareZoomPolicy.pointerSlowdown`'s glass speed, re-read at each zoom start so it
    /// can be tuned live: `defaults write ro.victorrentea.macos-addons ZoomPointerGlassSpeed -float 0.6`.
    private var glassSpeed = ShareZoomPolicy.defaultGlassSpeed
    static let glassSpeedKey = "ZoomPointerGlassSpeed"
    /// Where the cursor was put last, with its fractions; nil until the first move.
    private var pos: CGPoint?
    /// The zoomed display and the slice of it on the glass, CG global, from the last
    /// tick (`ShareZoomEdge`). Nil = no edge rules, only the slowdown.
    private var display: CGRect?
    private var slice: CGRect?

    init() { createTap() }

    /// Main thread, every zoom tick.
    func follow(factor: CGFloat, display: CGRect? = nil, slice: CGRect? = nil) {
        let k = max(factor, 1)
        lock.lock()
        let was = self.factor
        self.factor = k
        self.display = k > 1 ? display : nil
        self.slice = k > 1 ? slice : nil
        if k == 1 { pos = nil }
        lock.unlock()
        guard let port = tapPort, (was > 1) != (k > 1) else { return }
        if k > 1 {
            let stored = UserDefaults.standard.double(forKey: Self.glassSpeedKey)
            let g = stored > 0 ? CGFloat(stored) : ShareZoomPolicy.defaultGlassSpeed
            lock.lock(); glassSpeed = g; lock.unlock()
        }
        CGEvent.tapEnable(tap: port, enable: k > 1)
        overlayInfo("🔎 pointer at \(glassSpeed)× on the glass: \(k > 1 ? "on" : "off")")
    }

    func restore() { follow(factor: 1) }

    /// The edge pan moved the picture by `d` (desktop units, CG): the pointer goes with
    /// it, so it stays at the same spot on the glass. Main thread.
    func shift(by d: CGVector) {
        lock.lock(); defer { lock.unlock() }
        guard factor > 1, let p = pos ?? CGEvent(source: nil)?.location else { return }
        let next = CGPoint(x: p.x + d.dx, y: p.y + d.dy)
        pos = next
        CGWarpMouseCursorPosition(next)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

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
        // From the event's own delta, never from `now − last`: WindowServer rounds the
        // warped position, and that rounding ate most of every slow move — the cursor
        // all but froze (2026-10-27, the first build of this).
        let rawDX = event.getDoubleValueField(.mouseEventDeltaX)
        let rawDY = event.getDoubleValueField(.mouseEventDeltaY)
        // Off the zoomed display the mouse is its own, at normal speed; coming back
        // onto it, it enters the slice where the hand crosses the glass edge.
        if let display, let slice, let last = pos, !display.contains(last) {
            guard display.contains(now) else {
                pos = now
                return Unmanaged.passUnretained(event)
            }
            let entry = ShareZoomEdge.fromGlass(now, slice: slice, display: display)
            pos = entry
            CGWarpMouseCursorPosition(entry)
            CGAssociateMouseAndMouseCursorPosition(1)
            event.location = entry
            return Unmanaged.passUnretained(event)
        }
        // The first move, or the cursor put somewhere by someone else (a warp, a
        // display change): follow it rather than scale it.
        guard let last = pos, !ShareZoomPolicy.followsUnscaled(
            now: now, last: last, delta: CGVector(dx: rawDX, dy: rawDY)) else {
            pos = now
            return Unmanaged.passUnretained(event)
        }
        let slow = Double(ShareZoomPolicy.pointerSlowdown(factor, glassSpeed: glassSpeed))
        let dx = rawDX / slow
        let dy = rawDY / slow
        let moved = CGPoint(x: last.x + dx, y: last.y + dy)
        let next: CGPoint
        if let display, let slice, slice.contains(last) {
            // The slice's edge is the screen's edge: across it, onto the next display
            // at the matching glass spot, the picture left where it was (`ShareZoomEdge`).
            next = ShareZoomEdge.confine(moved, slice: slice, display: display) { p in
                var id = CGDirectDisplayID(0), n: UInt32 = 0
                return CGGetDisplaysWithPoint(p, 1, &id, &n) == .success && n > 0
            }
        } else {
            next = Self.clampToDisplay(moved, from: last)
        }
        pos = next
        CGWarpMouseCursorPosition(next)
        // A warp mutes the mouse for 0.25 s; re-associating lifts that at once.
        CGAssociateMouseAndMouseCursorPosition(1)
        event.location = next
        event.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        return Unmanaged.passUnretained(event)
    }

    /// `p` if some display holds it, else pulled back inside the display `from` is on —
    /// or `pos` runs on past the edge and the hand has to undo it before the cursor moves.
    private static func clampToDisplay(_ p: CGPoint, from: CGPoint) -> CGPoint {
        var id = CGDirectDisplayID(0), n: UInt32 = 0
        if CGGetDisplaysWithPoint(p, 1, &id, &n) == .success, n > 0 { return p }
        guard CGGetDisplaysWithPoint(from, 1, &id, &n) == .success, n > 0 else { return from }
        let r = CGDisplayBounds(id)
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }
}
