import AppKit
import ApplicationServices

/// ⌃⌥⌘ + arrow → the focused window takes that half of its own screen;
/// fn⌃⌥⌘ + arrow → it jumps to the screen in that direction; F3 → Window ▸ Fill
/// that a second F3 takes back.
///
/// All three work on the focused window of the frontmost app, over Accessibility —
/// the same grant `TerminalTiler` already relies on. Every rectangle here is in
/// the global **top-left** point space AX speaks, so `NSScreen.visibleFrame` is
/// flipped once on the way in and nothing else converts.
///
/// **Bare ⌃⌥ + arrow is Magnet's** (left/right/top/bottom half, running since
/// login) and must fall through: this took it for a few hours on 2026-10-05 and
/// Magnet went deaf. ⌘ on top is free in Magnet's active layout.
///
/// The 🪞 Virtual Desktop's screen is skipped (`NSScreen.physical`): nobody sees
/// it, so a window thrown there by an arrow would simply vanish.
enum WindowScreenMove {

    enum Direction { case left, right, up, down }

    /// What a ⌃⌥⌘ keystroke asks for. With fn held the arrows arrive as
    /// Home / End / PgUp / PgDn — that keycode is what says "another screen".
    enum Key: Equatable {
        case half(Direction)
        case screen(Direction)

        init?(keyCode: Int) {
            switch keyCode {
            case 123: self = .half(.left)
            case 124: self = .half(.right)
            case 126: self = .half(.up)
            case 125: self = .half(.down)
            case 115: self = .screen(.left)    // fn← = Home
            case 119: self = .screen(.right)   // fn→ = End
            case 116: self = .screen(.up)      // fn↑ = Page Up
            case 121: self = .screen(.down)    // fn↓ = Page Down
            default: return nil
            }
        }
    }

    static func run(_ key: Key) {
        guard let window = focusedWindow(), let frame = AXWindows.frame(of: window) else { return }
        let screens = visibleScreens()
        guard let src = WindowScreenMovePolicy.screenIndex(containing: frame, in: screens) else { return }
        switch key {
        case .half(let direction):
            AXWindows.setFrame(window, WindowScreenMovePolicy.half(of: screens[src], direction))
        case .screen(let direction):
            guard let dst = WindowScreenMovePolicy.neighbour(of: src, direction, in: screens) else { return }
            AXWindows.setFrame(window, WindowScreenMovePolicy.relocate(frame, from: screens[src], to: screens[dst]))
        }
    }

    // MARK: - F3 fill / restore

    private static let lock = NSLock()
    /// The frame each window had just before F3 filled it. Matched with `CFEqual`,
    /// which is how AX elements compare; a handful at most, so a list is enough.
    private static var beforeFill: [(window: AXUIElement, frame: CGRect)] = []

    /// First F3 remembers the frame and fills; the next F3 on the same window puts
    /// the remembered frame back. If the window already sits exactly where it was
    /// remembered (put back by hand), the memory is stale and F3 fills again.
    static func toggleFill() {
        guard let window = focusedWindow(), let frame = AXWindows.frame(of: window) else {
            KeySimulator.fillWindow()
            return
        }
        lock.lock()
        let i = beforeFill.firstIndex { CFEqual($0.window, window) }
        let saved = i.map { beforeFill.remove(at: $0).frame }
        if saved == nil || saved == frame {
            beforeFill.append((window, frame))
            if beforeFill.count > 20 { beforeFill.removeFirst() }
        }
        lock.unlock()

        if let saved, saved != frame {
            AXWindows.setFrame(window, saved)
        } else {
            KeySimulator.fillWindow()
        }
    }

    // MARK: - Plumbing

    /// Own application element with the system's default AX timeout: a resize
    /// makes the app relayout, which can outlast `AXWindows`' 0.1 s tap-thread cap.
    /// We are on a background queue here, not on the tap.
    private static func focusedWindow() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                            kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Every screen's `visibleFrame` (menu bar and Dock off), flipped to top-left.
    private static func visibleScreens() -> [CGRect] {
        let read = {
            guard let primary = NSScreen.screens.first else { return [CGRect]() }
            let top = primary.frame.maxY
            return NSScreen.physical.map { s in
                let v = s.visibleFrame
                return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
            }
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
}

/// The geometry, kept pure so it can be tested without a screen.
enum WindowScreenMovePolicy {

    /// The screen holding most of the window.
    static func screenIndex(containing window: CGRect, in screens: [CGRect]) -> Int? {
        let areas = screens.map { s -> CGFloat in
            let i = s.intersection(window)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        // Off every screen (it happens): the nearest centre.
        return screens.indices.min { distance(screens[$0].center, window.center) < distance(screens[$1].center, window.center) }
    }

    /// The screen in `direction` from `screens[src]`: its centre must lie that way,
    /// and among those the one sharing the most edge with the source wins (a
    /// screen straight above beats one above-and-far-right), then the closest.
    static func neighbour(of src: Int, _ direction: WindowScreenMove.Direction, in screens: [CGRect]) -> Int? {
        let s = screens[src]
        let candidates = screens.indices.filter { i in
            guard i != src else { return false }
            let d = screens[i]
            switch direction {
            case .left:  return d.midX < s.midX && d.maxX <= s.midX
            case .right: return d.midX > s.midX && d.minX >= s.midX
            case .up:    return d.midY < s.midY && d.maxY <= s.midY
            case .down:  return d.midY > s.midY && d.minY >= s.midY
            }
        }
        func overlap(_ d: CGRect) -> CGFloat {
            switch direction {
            case .left, .right: return max(0, min(s.maxY, d.maxY) - max(s.minY, d.minY))
            case .up, .down:    return max(0, min(s.maxX, d.maxX) - max(s.minX, d.minX))
            }
        }
        return candidates.min { a, b in
            let oa = overlap(screens[a]) > 0, ob = overlap(screens[b]) > 0
            if oa != ob { return oa }
            return distance(screens[a].center, s.center) < distance(screens[b].center, s.center)
        }
    }

    /// That half of the screen: ← the left one, ↑ the top one, and so on.
    static func half(of s: CGRect, _ direction: WindowScreenMove.Direction) -> CGRect {
        let w = (s.width / 2).rounded(), h = (s.height / 2).rounded()
        switch direction {
        case .left:  return CGRect(x: s.minX, y: s.minY, width: w, height: s.height)
        case .right: return CGRect(x: s.maxX - w, y: s.minY, width: w, height: s.height)
        case .up:    return CGRect(x: s.minX, y: s.minY, width: s.width, height: h)
        case .down:  return CGRect(x: s.minX, y: s.maxY - h, width: s.width, height: h)
        }
    }

    /// The window lands where it was **proportionally**: a left half stays a left
    /// half, a quarter a quarter, a filled window fills the new screen — whatever
    /// the two screens' sizes. Clamped so it never ends up larger than the target.
    static func relocate(_ w: CGRect, from src: CGRect, to dst: CGRect) -> CGRect {
        let sx = dst.width / src.width, sy = dst.height / src.height
        let width = min(dst.width, (w.width * sx).rounded())
        let height = min(dst.height, (w.height * sy).rounded())
        var x = (dst.minX + (w.minX - src.minX) * sx).rounded()
        var y = (dst.minY + (w.minY - src.minY) * sy).rounded()
        x = min(max(x, dst.minX), dst.maxX - width)
        y = min(max(y, dst.minY), dst.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
