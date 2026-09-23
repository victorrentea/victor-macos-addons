import CoreGraphics
import Foundation

/// When the cursor is held on its screen. Pure, so the rule can be tested without a
/// magnifier, a tap or a second monitor.
enum ZoomLensCursorFencePolicy {

    /// Fenced only while a picture-in-picture lens is **actually magnifying**.
    ///
    /// The zoom factor is part of the gate on purpose: scrolling ⌥+wheel back down to
    /// 1× is the way out. With no key of its own to learn, "zoom out, then go to the
    /// other screen" is the gesture Victor already makes. Full screen and split screen
    /// never fence: the flicker this exists for is the PiP lens being dragged off the
    /// shared screen, and the other styles do not jump like that.
    static func shouldFence(mode: ZoomLensMode?, zoomedIn: Bool, factor: Double) -> Bool {
        mode == .pictureInPicture && zoomedIn && factor > 1.001
    }

    /// The point pulled back inside `rect`. The far edges are exclusive (`maxX - 1`),
    /// because a point *on* `maxX` already belongs to the display next door.
    static func clamp(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, rect.minX), rect.maxX - 1),
                y: min(max(p.y, rect.minY), rect.maxY - 1))
    }
}

/// 🔍 Holds the cursor on the screen being magnified while a PiP lens is zoomed in.
///
/// **The problem (2026-09-23).** With the magnifier in picture-in-picture style (the
/// only style a Zoom share carries, see `ZoomLensMode`), moving the pointer off the
/// retina onto the ASUS drops the magnification abruptly and brings it back when
/// the pointer returns: a nervous flicker on the screen the room and the call
/// are both watching. macOS has no setting that keeps the lens where it is. Tried the
/// same day: `closeViewZoomDisplayID` is a full-screen-style chooser, and nothing in
/// `UniversalAccessCore`'s exports pins a PiP lens. So instead of keeping the lens
/// when the cursor leaves, the cursor is simply not allowed to leave.
///
/// **How: an HID-level tap that rewrites the location of every move and drag.**
/// Measured with a prototype before this was written: 98 moves aimed at the ASUS
/// were clamped and the cursor stopped at `x = -1`, the retina's right edge. Warping
/// the cursor back *after* it crosses (`CGWarpMouseCursorPosition`) is the obvious
/// alternative and exactly wrong here: by then the pointer has already been on the
/// other display for a frame, which is the flicker itself.
///
/// **The tap exists all the time but is enabled only while fenced**, so outside a
/// zoom not a single mouse move takes a detour through this process. The gate is
/// three `com.apple.universalaccess` keys read every 0.25 s: the magnifier offers no
/// notification, and a key tap cannot see its gestures (see `ZoomLensWatch`).
///
/// **Which screen**: whichever one holds the cursor at the moment the fence goes up,
/// taken from the mirror *master*. A mirrored projector sits on the same rectangle as
/// the retina, so the answer is the same either way, but the master is the one that
/// is reliably reported. Normally that is the retina, where the lens lives.
final class ZoomLensCursorFence {

    private static let domain = "com.apple.universalaccess" as CFString

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.zoom-lens-fence",
                                      qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var tapPort: CFMachPort?

    /// Written on `queue`, read on the tap thread for every move: hence the lock.
    private let lock = NSLock()
    private var fenceRect: CGRect?

    func start() {
        guard createTap() else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 0.25)
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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let fenced = fenceRect != nil; lock.unlock()
            if fenced, let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        lock.lock(); let rect = fenceRect; lock.unlock()
        if let rect, !rect.contains(event.location) {
            event.location = ZoomLensCursorFencePolicy.clamp(event.location, to: rect)
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

        lock.lock(); let fenced = fenceRect != nil; lock.unlock()
        guard want != fenced, let port = tapPort else { return }

        if want {
            guard let rect = Self.screenUnderCursor() else { return }
            lock.lock(); fenceRect = rect; lock.unlock()
            CGEvent.tapEnable(tap: port, enable: true)
            overlayInfo("🔍 PiP zoomed in — cursor fenced to \(rect)")
        } else {
            CGEvent.tapEnable(tap: port, enable: false)
            lock.lock(); fenceRect = nil; lock.unlock()
            overlayInfo("🔍 cursor fence released")
        }
    }

    /// Bounds of the display the cursor is on, preferring a mirror master over its
    /// slaves (they share the rectangle; the master is the one Quartz names).
    private static func screenUnderCursor() -> CGRect? {
        guard let p = CGEvent(source: nil)?.location else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        guard CGGetDisplaysWithPoint(p, 8, &ids, &n) == .success, n > 0 else { return nil }
        let hits = ids.prefix(Int(n))
        let id = hits.first { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay } ?? hits.first!
        return CGDisplayBounds(id)
    }

    deinit { timer?.cancel() }
}
