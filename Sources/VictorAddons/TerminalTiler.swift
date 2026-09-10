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
    /// (⌘⌃T / ⌘⌃C) tiles the screen it just landed on and leaves the
    /// windows on every other screen exactly where they were — the gesture said
    /// "make room here", not "rearrange all my monitors".
    /// **Tiling never moves the keyboard, and it gives it the best seat.** The
    /// window that was being typed in is noted before anything is moved: it is
    /// pinned to the largest slot nothing else is stacked on top of
    /// (`TerminalTileLayout.topSlots` — in practice a whole quadrant, usually the
    /// top-left, since `fillOrder` piles the bottom of the screen first), and it is
    /// raised once more at the very end, so it is the one left focused. Arranging
    /// windows is not a reason to make the next keystrokes land in a different
    /// terminal, and the terminal being typed in is the one that should be big and
    /// unobstructed. Those two used to collide when the focused window sat at the
    /// back of a pile — raising it last covered the windows lying on it; now it is
    /// never at the back of a pile in the first place.
    ///
    /// **Tiling does not renumber ⌘`.** The windows come out of it stacked exactly
    /// as they went in (`raisePreservingOrder`), because macOS walks an app's
    /// windows with ⌘` / ⌘⇧` in z-order: re-stacking them means that "the terminal
    /// I was in a moment ago" is a different terminal after a tile than it was
    /// before it. The pile still has to read from big to small, and depth in a pile
    /// *is* z-order — so the pile is made to fit the stack rather than the stack
    /// the pile: `TerminalTileLayout.dealPilesByDepth` gives the deepest slot of a
    /// quadrant to whichever of its windows is already the back-most.
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

        var tiled: [AXUIElement] = []
        for (di, ws) in groups {
            if let displayID, displays[di].id != displayID { continue }
            let slots = TerminalTileLayout.targets(count: ws.count, display: displays[di].usable)
            let assignment = TerminalTileLayout.assign(
                windows: ws.map { $0.rect }, display: displays[di].usable,
                focused: focused.flatMap { f in ws.firstIndex { CFEqual($0.win, f) } })
            for (i, w) in ws.enumerated() {
                let f = slots[assignment[i]]
                setWindowFrame(w.win, x: f.x, y: f.y, w: f.w, h: f.h)
            }
            tiled.append(contentsOf: ws.map { $0.win })
        }

        raisePreservingOrder(wins.map { $0.win }, touched: tiled)

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

    /// Every display twice over: its `bounds`, which is what a window's centre is
    /// tested against, and the `usable` rect the tiles are actually laid out in.
    ///
    /// **They are not the same rect, and tiling into the wrong one collides two
    /// windows into one.** `CGDisplayBounds` includes the menu bar, which no window
    /// may occupy: the deepest window of a top quadrant was placed at y = 2, macOS
    /// clamped it down to just under the menu bar, and the window one step behind
    /// it — placed 32 pt lower, i.e. at almost exactly the same y — ended up with
    /// its title bar sitting on the first one's (2026-09-09: *"the two window
    /// titles of top terminals are overlapped"*). The whole staircase is built out
    /// of 32 pt steps, so a 30-odd point clamp eats a step entirely. `visibleFrame`
    /// is the honest rectangle — menu bar off the top, Dock off whichever edge it
    /// is on — so the steps land where they were computed.
    private static func getDisplays() -> [(id: CGDirectDisplayID, bounds: Rect, usable: Rect)] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let usableByID = usableRects()
        return ids.map {
            let b = CGDisplayBounds($0)
            let bounds = Rect(x: Int(b.origin.x), y: Int(b.origin.y),
                              w: Int(b.size.width), h: Int(b.size.height))
            return (id: $0, bounds: bounds, usable: usableByID[$0] ?? bounds)
        }
    }

    /// `NSScreen.visibleFrame` per display, flipped from AppKit's bottom-left
    /// origin into the top-left global space that `CGDisplayBounds` and the
    /// Accessibility API both speak. Read on the main thread — ⌘⌃A reaches here
    /// from a background queue as well as from the menu.
    private static func usableRects() -> [CGDirectDisplayID: Rect] {
        onMain {
            guard let primary = NSScreen.screens.first else { return [:] }
            let top = primary.frame.maxY
            var out: [CGDirectDisplayID: Rect] = [:]
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                let v = screen.visibleFrame
                out[number.uint32Value] = Rect(x: Int(v.origin.x), y: Int(top - v.maxY),
                                               w: Int(v.width), h: Int(v.height))
            }
            return out
        }
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private static func displayFor(cx: Double, cy: Double,
                                   displays: [(id: CGDirectDisplayID, bounds: Rect, usable: Rect)]) -> Int {
        for (i, e) in displays.enumerated() {
            let d = e.bounds
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

    /// Put the windows back in **exactly the front-to-back order they were in**,
    /// by raising them back-most first: each raise brings one window to the front,
    /// so the last one raised — the one that was in front to begin with — is in
    /// front again, and everything behind it is in the order it already had.
    ///
    /// **That order is the ⌘` order**, which is the whole reason this walk exists
    /// in this shape (2026-09-10: *"după reordonare, SECVENŢA terminalelor să se
    /// păstreze … să pot merge înapoi pe terminalul precedent"*). macOS cycles an
    /// app's windows through its z-order, so a tile that re-stacks the terminals
    /// re-numbers the whole keyboard walk: ⌘⇧` after a tile used to land in a
    /// different session than ⌘⇧` a second earlier. Arranging windows is no more a
    /// reason to renumber the ⌘` cycle than it is to move the keyboard — the same
    /// rule as the focused window, one level up.
    ///
    /// It used to raise in **slot order** instead, deepest window of each pile
    /// first, because depth and z-order are the same thing in a cascade and the
    /// pile has to read bigger-to-smaller. That job has moved to where it costs
    /// nothing: `TerminalTileLayout.dealPilesByDepth` hands the deepest slot to the
    /// window that is *already* back-most, so the pile comes out right with the
    /// stack left alone. Get neither right and the pile is technically cascaded and
    /// practically a single window (2026-09-08: *"restul sunt una sub alta"*).
    ///
    /// Only `touched` windows are raised — with `onDisplay`, the terminals on the
    /// other monitors are not lifted above whatever is covering them there — but
    /// the walk still runs over all of `wins`, i.e. across displays in one pass, so
    /// two tiled screens cannot end up stacked one entirely in front of the other.
    /// Raising the set does put it above the other apps on those screens, which is
    /// the other half of what this is for: a tile you cannot see has not been
    /// tiled.
    ///
    /// **Depth and the keyboard are the same thing here.** Measured 2026-09-08:
    /// `kAXRaiseAction` on a Terminal window makes it the key window, and the other
    /// direction holds too — setting `AXMain`/`AXFocused` on a window at the back
    /// brings it straight to `z00`. Terminal will not keep the keyboard in a window
    /// that is not in front, so this walk cannot have the last word: `tile` raises
    /// the previously focused window after it, and **that** is the one left on top.
    /// In the ordinary case that costs nothing, the focused window being the one
    /// that was in front anyway — so the raise it ends on is the raise this walk
    /// would have ended on.
    private static func raisePreservingOrder(_ wins: [AXUIElement], touched: [AXUIElement]) {
        for win in wins.reversed() where touched.contains(where: { CFEqual($0, win) }) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
    }
}
