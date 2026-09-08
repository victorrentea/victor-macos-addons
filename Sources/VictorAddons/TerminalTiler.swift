import AppKit
import CoreGraphics
import ApplicationServices

/// Snaps each Terminal window to the nearest free quadrant of its current monitor.
/// Minimizes total movement (brute-force permutations — fine for ≤4 windows per monitor).
/// Windows stay on whichever display they currently occupy. From the fifth window
/// on there is no quadrant left, so the extras are **cascaded** over the
/// bottom-right one and raised above it — see `TerminalTileLayout`.
///
/// Window geometry is read/written through the in-process **Accessibility API**
/// (`AXUIElement`), which relies only on this app's own Accessibility grant — the
/// same one that powers the global event tap. The previous implementation shelled
/// out to `osascript` + "System Events" UI scripting, which needs a *separate*
/// Automation (Apple Events) grant; after any re-sign that grant's code requirement
/// no longer matched the running binary, so the Apple Event blocked on a consent
/// prompt that a headless subprocess can't surface and tiling silently timed out.
enum TerminalTiler {

    private static let MARGIN = 2
    private static let terminalBundleID = "com.apple.Terminal"

    /// Geometry (and every decision made with it) lives in the pure, testable
    /// `TerminalTileLayout`; this file is only the Accessibility plumbing.
    private typealias Rect = TerminalTileLayout.Rect

    /// Tile every Terminal window, each on the display it already sits on.
    ///
    /// `onDisplay` narrows that to a single monitor: the shortcut-opened Terminal
    /// (⌘⌃T / ⌘⌃C / ⌘⌃Q) tiles the screen it just landed on and leaves the
    /// windows on every other screen exactly where they were — the gesture said
    /// "make room here", not "rearrange all my monitors".
    static func tile(onDisplay displayID: CGDirectDisplayID? = nil) {
        let displays = getDisplays()
        let wins = getTerminalWindows()
        guard !displays.isEmpty, !wins.isEmpty else { return }

        var groups: [Int: [(win: AXUIElement, rect: Rect)]] = [:]
        for w in wins {
            let (cx, cy) = w.rect.center
            let di = displayFor(cx: cx, cy: cy, displays: displays)
            groups[di, default: []].append(w)
        }

        for (di, ws) in groups {
            if let displayID, displays[di].id != displayID { continue }
            let frames = TerminalTileLayout.frames(windows: ws.map { $0.rect },
                                                   display: displays[di].rect)
            for (i, w) in ws.enumerated() {
                let f = frames[i]
                setWindowFrame(w.win, x: f.x, y: f.y, w: f.w, h: f.h)
            }
            raiseCascade(Array(ws.dropFirst(4).map { $0.win }), front: ws.first?.win)
        }
    }

    // MARK: - Displays

    private static func getDisplays() -> [(id: CGDirectDisplayID, rect: Rect)] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map {
            let b = CGDisplayBounds($0)
            return (id: $0,
                    rect: Rect(x: Int(b.origin.x), y: Int(b.origin.y),
                               w: Int(b.size.width), h: Int(b.size.height)))
        }
    }

    private static func displayFor(cx: Double, cy: Double,
                                   displays: [(id: CGDirectDisplayID, rect: Rect)]) -> Int {
        for (i, e) in displays.enumerated() {
            let d = e.rect
            if Double(d.x) <= cx, cx < Double(d.x2),
               Double(d.y) <= cy, cy < Double(d.y2) { return i }
        }
        return 0
    }

    // MARK: - Terminal windows (Accessibility API)

    /// Read every Terminal window's frame via AX. Position/size are in the global
    /// top-left-origin point space — the same space as `CGDisplayBounds`, so the
    /// quadrant math below needs no conversion. Returns the live `AXUIElement` for
    /// each window so we can write the new frame straight back to it.
    private static func getTerminalWindows() -> [(win: AXUIElement, rect: Rect)] {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: terminalBundleID).first else {
            return []
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }
        return windows.compactMap { win in
            guard let pos = axValue(of: win, kAXPositionAttribute, type: .cgPoint, as: CGPoint.self),
                  let size = axValue(of: win, kAXSizeAttribute, type: .cgSize, as: CGSize.self) else {
                return nil
            }
            return (win: win,
                    rect: Rect(x: Int(pos.x), y: Int(pos.y),
                               w: Int(size.width), h: Int(size.height)))
        }
    }

    private static func setWindowFrame(_ win: AXUIElement, x: Int, y: Int, w: Int, h: Int) {
        var point = CGPoint(x: x, y: y)
        if let posValue = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posValue)
        }
        var size = CGSize(width: w, height: h)
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    /// Read an `AXValue`-wrapped struct (CGPoint/CGSize) attribute off `el`.
    private static func axValue<T>(of el: AXUIElement, _ attr: String,
                                   type: AXValueType, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(axValue, type, out) else { return nil }
        return out.pointee
    }

    // MARK: - Stacking order

    /// Move the cascaded windows in front of the quadrant window they now sit on.
    ///
    /// Frames say nothing about depth, and depth is half of what makes a fan
    /// legible. The extras are the *back*-most windows (that is how they came to be
    /// extras), so without this they would be tiled into a neat pile hidden behind
    /// the bottom-right tile. They are raised **back-to-front**, which — with
    /// `TerminalTileLayout` giving the front-most extra the deepest slot — leaves
    /// the lowest window on top and a full title bar of every window behind it
    /// showing above. Raise them the other way round and each title bar is covered
    /// but for a 32 pt sliver: fanned in geometry, a single window to the eye.
    /// The window that was front before is raised last, so tiling does not take the
    /// keyboard away from the terminal being typed in — it sits in another quadrant,
    /// by construction, so putting it back on top hides nothing.
    private static func raiseCascade(_ cascaded: [AXUIElement], front: AXUIElement?) {
        guard !cascaded.isEmpty else { return }
        for win in cascaded.reversed() {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
        if let front { AXUIElementPerformAction(front, kAXRaiseAction as CFString) }
    }
}
