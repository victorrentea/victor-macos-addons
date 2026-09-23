import CoreGraphics
import Foundation

/// The sides of a display that touch another one: the only ways out for the cursor.
struct FenceEdges: OptionSet, Equatable {
    let rawValue: Int
    static let left   = FenceEdges(rawValue: 1 << 0)
    static let right  = FenceEdges(rawValue: 1 << 1)
    static let top    = FenceEdges(rawValue: 1 << 2)
    static let bottom = FenceEdges(rawValue: 1 << 3)
}

/// When the cursor is held on its screen, and how it moves while held. Pure, so the
/// rules can be tested without a magnifier, a tap or a second monitor.
enum ZoomLensCursorFencePolicy {

    /// Width of the strip along an exit edge where the mouse is decoupled.
    static let band: CGFloat = 80
    /// Re-couple only this far past the band's inner line, so a hand resting on the
    /// line does not flap between the two modes.
    static let hysteresis: CGFloat = 6
    /// Decoupled, macOS reports the mouse's **raw** motion, before its acceleration
    /// curve. Measured on 2026-09-23 with Victor's Logitech: 16.9 raw units per event
    /// against 4.0 points per event coupled, i.e. ×4.2. Dividing by 4.2 felt slow
    /// (the curve adds speed to fast strokes that a constant cannot), dividing by 1
    /// was unusable; 3.3 is the compromise, and it only applies inside the band.
    static let rawScale: Double = 1 / 3.3

    /// Fenced only while a picture-in-picture lens is **actually magnifying**.
    /// ⌥+scroll back down to 1× is the way out.
    static func shouldFence(mode: ZoomLensMode?, zoomedIn: Bool, factor: Double) -> Bool {
        mode == .pictureInPicture && zoomedIn && factor > 1.001
    }

    /// Which sides of `rect` another display touches (sharing a side, with some overlap
    /// along it). Mirror slaves sit on `rect` itself and touch nothing.
    static func exitEdges(of rect: CGRect, others: [CGRect]) -> FenceEdges {
        var e: FenceEdges = []
        for o in others where o != rect {
            let vOverlap = o.minY < rect.maxY && o.maxY > rect.minY
            let hOverlap = o.minX < rect.maxX && o.maxX > rect.minX
            if vOverlap && o.minX == rect.maxX { e.insert(.right) }
            if vOverlap && o.maxX == rect.minX { e.insert(.left) }
            if hOverlap && o.minY == rect.maxY { e.insert(.bottom) }
            if hOverlap && o.maxY == rect.minY { e.insert(.top) }
        }
        return e
    }

    /// Is `p` within `inset` of one of the exit edges (or already past it)?
    static func inBand(_ p: CGPoint, rect: CGRect, edges: FenceEdges, inset: CGFloat = band) -> Bool {
        (edges.contains(.right)  && p.x >= rect.maxX - inset) ||
        (edges.contains(.left)   && p.x <  rect.minX + inset) ||
        (edges.contains(.bottom) && p.y >= rect.maxY - inset) ||
        (edges.contains(.top)    && p.y <  rect.minY + inset)
    }

    /// The point pulled back inside `rect`. The far edges are exclusive (`maxX - 1`),
    /// because a point *on* `maxX` already belongs to the display next door.
    static func clamp(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, rect.minX), rect.maxX - 1),
                y: min(max(p.y, rect.minY), rect.maxY - 1))
    }

    /// One decoupled step: raw delta scaled to points, clamped to the screen.
    static func step(from p: CGPoint, rawDX: Double, rawDY: Double, in rect: CGRect) -> CGPoint {
        clamp(CGPoint(x: p.x + rawDX * rawScale, y: p.y + rawDY * rawScale), to: rect)
    }
}

/// 🔍 Holds the cursor on the screen being magnified while a PiP lens is zoomed in.
///
/// **The problem (2026-09-23).** With the magnifier in picture-in-picture style (the
/// only style a Zoom share carries, see `ZoomLensMode`), moving the pointer off the
/// retina onto the ASUS drops the magnification abruptly: a nervous flicker on the
/// screen the room and the call are both watching. macOS has no setting that keeps
/// the lens: `closeViewZoomDisplayID` is the full-screen style's chooser, and nothing
/// in `UniversalAccessCore` pins a PiP lens.
///
/// **What did not work, all tested live with Victor's hand on the mouse:**
/// - Rewriting `event.location` in an HID tap. It changes what *apps* are told, not
///   where WindowServer draws the cursor: a prototype driven by synthetic moves
///   stopped at the edge, the physical mouse sailed through. (The logger that
///   "confirmed" it read the location from events too, so it was fooled the same way.)
/// - That, plus `CGWarpMouseCursorPosition` back: the crossing has already happened.
/// - `SLSSetCursorRegionLock` and `SLSSetZoomForceLockCursorInDisplay` (SkyLight,
///   private): both return success and hold nothing for a background process.
///
/// **What works: decoupling the mouse from the cursor**
/// (`CGAssociateMouseAndMouseCursorPosition(false)`) and moving the cursor ourselves,
/// clamped. Victor confirmed the cursor could no longer leave the retina. The price:
/// decoupled, the deltas are **raw** — ×4.2 the points macOS would have moved, with no
/// acceleration curve — so moving that way everywhere felt far too fast, and scaled by
/// a constant it felt slow. Hence the **band**: the mouse stays coupled (native feel)
/// except within 80 pt of an edge that leads to another display, where it is decoupled
/// and driven by `rawScale`. Leaving the band inward couples it again.
///
/// **The tap is enabled only while fenced**, and the gate is three
/// `com.apple.universalaccess` keys read every 0.1 s — the magnifier offers no
/// notification, and a key tap cannot see its gestures (see `ZoomLensWatch`). When the
/// gate drops (zoom out, style change) the mouse is always coupled back first.
final class ZoomLensCursorFence {

    private static let domain = "com.apple.universalaccess" as CFString

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.zoom-lens-fence",
                                      qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var tapPort: CFMachPort?

    /// Shared between `queue` (gate) and the tap thread (every move): hence the lock.
    private let lock = NSLock()
    private var fence: (rect: CGRect, edges: FenceEdges)?
    private var decoupled = false
    private var pos = CGPoint.zero

    func start() {
        guard createTap() else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func createTap() -> Bool {
        let mask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let fence = Unmanaged<ZoomLensCursorFence>.fromOpaque(userInfo!).takeUnretainedValue()
                return fence.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            overlayError("ZoomLensCursorFence: could not create HID tap — check Accessibility")
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        tapPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "ZoomLensCursorFence"
        thread.start()
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock(); defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if fence != nil, let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let (rect, edges) = fence else { return Unmanaged.passUnretained(event) }
        typealias P = ZoomLensCursorFencePolicy

        if !decoupled {
            let p = event.location
            guard P.inBand(p, rect: rect, edges: edges) || !rect.contains(p) else {
                return Unmanaged.passUnretained(event)
            }
            pos = P.clamp(p, to: rect)
            CGWarpMouseCursorPosition(pos)
            CGAssociateMouseAndMouseCursorPosition(0)
            decoupled = true
            event.location = pos
            return Unmanaged.passUnretained(event)
        }

        pos = P.step(from: pos,
                     rawDX: event.getDoubleValueField(.mouseEventDeltaX),
                     rawDY: event.getDoubleValueField(.mouseEventDeltaY),
                     in: rect)
        CGWarpMouseCursorPosition(pos)
        event.location = pos
        if !P.inBand(pos, rect: rect, edges: edges, inset: P.band + P.hysteresis) {
            CGAssociateMouseAndMouseCursorPosition(1)
            decoupled = false
        }
        return Unmanaged.passUnretained(event)
    }

    private func tick() {
        CFPreferencesAppSynchronize(Self.domain)
        let mode = (CFPreferencesCopyAppValue("closeViewZoomMode" as CFString, Self.domain) as? Int)
            .flatMap(ZoomLensMode.init(rawValue:))
        let zoomedIn = (CFPreferencesCopyAppValue("closeViewZoomedIn" as CFString, Self.domain) as? Int) == 1
        let factor = (CFPreferencesCopyAppValue("closeViewZoomFactor" as CFString, Self.domain) as? Double) ?? 1
        let want = ZoomLensCursorFencePolicy.shouldFence(mode: mode, zoomedIn: zoomedIn, factor: factor)

        lock.lock(); let fenced = fence != nil; lock.unlock()
        guard want != fenced, let port = tapPort else { return }

        if want {
            guard let f = Self.fenceUnderCursor() else { return }
            lock.lock(); fence = f; decoupled = false; lock.unlock()
            CGEvent.tapEnable(tap: port, enable: true)
            overlayInfo("🔍 PiP zoomed in — cursor fenced to \(f.rect), exits \(f.edges.rawValue)")
        } else {
            CGEvent.tapEnable(tap: port, enable: false)
            lock.lock(); fence = nil; decoupled = false; lock.unlock()
            CGAssociateMouseAndMouseCursorPosition(1)
            overlayInfo("🔍 cursor fence released")
        }
    }

    /// The display the cursor is on (its mirror master) and the sides of it that lead
    /// to another display. `nil` when there is no way out — nothing to fence.
    private static func fenceUnderCursor() -> (rect: CGRect, edges: FenceEdges)? {
        guard let p = CGEvent(source: nil)?.location else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return nil }
        let masters = ids.prefix(Int(n)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let rects = masters.map { CGDisplayBounds($0) }
        guard let rect = rects.first(where: { $0.contains(p) }) else { return nil }
        let edges = ZoomLensCursorFencePolicy.exitEdges(of: rect, others: rects)
        return edges.isEmpty ? nil : (rect, edges)
    }

    deinit {
        timer?.cancel()
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
