import AppKit
import CoreGraphics
import ApplicationServices

/// Snaps each Terminal window to the nearest free quadrant of its current monitor.
/// Minimizes total movement (brute-force permutations — fine for ≤4 windows per monitor).
/// Windows stay on whichever display they currently occupy.
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

    private struct Rect {
        let x: Int, y: Int, w: Int, h: Int
        var x2: Int { x + w }
        var y2: Int { y + h }
        var center: (Double, Double) { (Double(x) + Double(w) / 2, Double(y) + Double(h) / 2) }
    }

    static func tile() {
        let displays = getDisplays()
        let wins = getTerminalWindows()
        guard !displays.isEmpty, !wins.isEmpty else { return }

        var groups: [Int: [(win: AXUIElement, rect: Rect)]] = [:]
        for w in wins {
            let (cx, cy) = w.rect.center
            let di = displayFor(cx: cx, cy: cy, displays: displays)
            groups[di, default: []].append(w)
        }

        for (di, var ws) in groups {
            let quads = quadrants(of: displays[di])
            ws = Array(ws.prefix(quads.count))
            let assignment = assignOptimally(windowRects: ws.map { $0.rect }, quads: quads)
            for (i, w) in ws.enumerated() {
                let q = quads[assignment[i]]
                setWindowFrame(w.win, x: q.x, y: q.y, w: q.w, h: q.h)
            }
        }
    }

    // MARK: - Displays

    private static func getDisplays() -> [Rect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map {
            let b = CGDisplayBounds($0)
            return Rect(x: Int(b.origin.x), y: Int(b.origin.y),
                        w: Int(b.size.width), h: Int(b.size.height))
        }
    }

    private static func displayFor(cx: Double, cy: Double, displays: [Rect]) -> Int {
        for (i, d) in displays.enumerated() {
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

    // MARK: - Quadrants & assignment

    private static func quadrants(of d: Rect) -> [Rect] {
        let hw = d.w / 2, hh = d.h / 2
        return [
            Rect(x: d.x + MARGIN,  y: d.y + MARGIN, w: hw - MARGIN, h: hh - MARGIN),
            Rect(x: d.x + hw,      y: d.y + MARGIN, w: hw - MARGIN, h: hh - MARGIN),
            Rect(x: d.x + MARGIN,  y: d.y + hh,     w: hw - MARGIN, h: hh - MARGIN),
            Rect(x: d.x + hw,      y: d.y + hh,     w: hw - MARGIN, h: hh - MARGIN),
        ]
    }

    private static func dist2(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = a.0 - b.0, dy = a.1 - b.1
        return dx*dx + dy*dy
    }

    private static func permutations(of n: Int, choose k: Int) -> [[Int]] {
        if k == 0 { return [[]] }
        var result: [[Int]] = []
        for i in 0..<n {
            for rest in permutations(of: n, choose: k - 1) where !rest.contains(i) {
                result.append([i] + rest)
            }
        }
        return result
    }

    private static func assignOptimally(windowRects: [Rect], quads: [Rect]) -> [Int] {
        var bestPerm: [Int] = []
        var bestCost = Double.infinity
        for perm in permutations(of: quads.count, choose: windowRects.count) {
            let cost = (0..<windowRects.count).reduce(0.0) { acc, i in
                acc + dist2(windowRects[i].center, quads[perm[i]].center)
            }
            if cost < bestCost { bestCost = cost; bestPerm = perm }
        }
        return bestPerm
    }
}
