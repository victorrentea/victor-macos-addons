import AppKit
import CoreGraphics
import ApplicationServices

/// Snaps each Terminal window to the nearest free quadrant of its current monitor.
/// Minimizes total movement (greedy nearest-pair — fine for a handful of windows
/// per monitor). Windows stay on whichever display they currently occupy. From the
/// fifth window on there is no whole quadrant left, so the extras **cascade inside
/// one** — Windows-style, each a step smaller than the one behind it and pinned to
/// the quadrant's bottom-right corner, filling bottom-right, then bottom-left,
/// top-right, top-left; see `TerminalTileLayout`.
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
    /// **Tiling never moves the keyboard.** The window that was being typed in is
    /// noted before anything is raised and raised once more at the very end, so it
    /// is the one left focused — arranging windows is not a reason to make the next
    /// keystrokes land in a different terminal. It is free for the three quadrants
    /// holding a single window; the one case where the two rules collide is a
    /// focused window at the *back* of a pile, where putting the keyboard back
    /// covers the smaller windows lying on it — and the keyboard wins.
    static func tile(onDisplay displayID: CGDirectDisplayID? = nil) {
        let displays = getDisplays()
        let focused = focusedWindow()
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
            let slots = TerminalTileLayout.targets(count: ws.count, display: displays[di].rect)
            let assignment = TerminalTileLayout.assign(windows: ws.map { $0.rect }, targets: slots)
            for (i, w) in ws.enumerated() {
                let f = slots[assignment[i]]
                setWindowFrame(w.win, x: f.x, y: f.y, w: f.w, h: f.h)
            }
            raiseInSlotOrder(ws.map { $0.win }, assignment: assignment)
        }

        // Last word: the keyboard goes back where it was.
        if let focused { AXUIElementPerformAction(focused, kAXRaiseAction as CFString) }
    }

    /// Terminal's key window, or nil.
    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: terminalBundleID).first else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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
    ///
    /// **Minimized windows are not windows on the screen.** A window in the Dock
    /// still answers AX with a position and a size (the frame it had when it was
    /// minimized), so left in it would eat a quadrant and — worse — get *unhidden*
    /// by the raise walk, dragging a terminal that was deliberately put away back
    /// into the arrangement. Tiling only ever arranges what is visible; whatever is
    /// in the Dock stays in the Dock, and the visible ones split the screen among
    /// themselves.
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
            guard !isMinimized(win),
                  let pos = axValue(of: win, kAXPositionAttribute, type: .cgPoint, as: CGPoint.self),
                  let size = axValue(of: win, kAXSizeAttribute, type: .cgSize, as: CGSize.self) else {
                return nil
            }
            return (win: win,
                    rect: Rect(x: Int(pos.x), y: Int(pos.y),
                               w: Int(size.width), h: Int(size.height)))
        }
    }

    /// `AXMinimized`, defaulting to "not minimized" when the attribute is missing —
    /// a window that cannot say it is in the Dock is treated as on screen.
    private static func isMinimized(_ win: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
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

    /// Raise every window on the display in **slot order**: top-left, top-right,
    /// bottom-left, bottom-right, and inside each quadrant its pile from the
    /// deepest window (the whole quadrant) to the smallest.
    ///
    /// That order is the pile: raising deepest-first leaves every window in front
    /// of the bigger one behind it, so every title bar and every Claude bubble in
    /// the pile stays visible. Reversed, the arrangement is technically cascaded
    /// and practically a single window (2026-09-08: *"restul sunt una sub alta"*).
    /// It also brings the whole set of terminals **above the other apps** on that
    /// screen — a window buried under Chrome is still buried after it has been
    /// given a frame, and a tile you cannot see has not been tiled.
    ///
    /// **Depth and the keyboard are the same thing here.** Measured 2026-09-08:
    /// `kAXRaiseAction` on a Terminal window makes it the key window, and the other
    /// direction holds too — setting `AXMain`/`AXFocused` on a window at the back
    /// brings it straight to `z00`. Terminal will not keep the keyboard in a window
    /// that is not in front, so this walk cannot have the last word: `tile` raises
    /// the previously focused window after it, and **that** is the one left on top.
    private static func raiseInSlotOrder(_ wins: [AXUIElement], assignment: [Int]) {
        for (win, _) in zip(wins, assignment).sorted(by: { $0.1 < $1.1 }) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
    }
}
