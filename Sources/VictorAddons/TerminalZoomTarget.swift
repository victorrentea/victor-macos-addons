import ApplicationServices
import CoreGraphics
import Foundation

/// One on-screen window as the window server describes it, cut down to what
/// picking a Cmd+scroll zoom target needs.
struct ZoomWindowInfo: Equatable {
    let pid: pid_t
    /// `kCGWindowLayer`. 0 is an ordinary document window; everything else is a
    /// panel, a menu, a dock tile or one of our own click-through overlays.
    let layer: Int
    let bounds: CGRect
}

/// Which window a Cmd+scroll zoom should act on.
enum TerminalZoomChoice: Equatable {
    /// The window the pointer is over, identified by the frame the window server
    /// reports for it — that frame is how it gets matched to an AX element.
    case windowUnderMouse(pid: pid_t, bounds: CGRect)
    /// Nothing zoomable under the pointer: fall back to the window that has the
    /// keyboard, which is what this gesture did before it learned about the mouse.
    case focusedWindow(pid: pid_t)
    case none
}

/// Pure half of the targeting: given where the pointer is and what the window
/// server says is on screen, which window does the zoom belong to.
enum TerminalZoomTargetPolicy {

    /// The window server hands windows back **front to back**, so the first
    /// ordinary-level window containing the point is the one the pointer is
    /// visibly over. Other layers are skipped rather than treated as a hit: a
    /// menu, a panel or one of this app's own click-through overlays cannot be
    /// zoomed, and must not hide the terminal underneath it either.
    static func windowUnderMouse(_ point: CGPoint, in windows: [ZoomWindowInfo]) -> ZoomWindowInfo? {
        windows.first { $0.layer == 0 && $0.bounds.contains(point) }
    }

    /// - Parameter frontmostTerminalPid: the active application, but only when it
    ///   is a terminal this gesture zooms; `nil` otherwise.
    ///
    /// The pointer only wins when the window under it belongs to the **active**
    /// terminal application. That restriction is not tidiness, it is what the
    /// platform allows: a terminal applies Bigger/Smaller to whichever of its
    /// windows holds the keyboard, and an inactive application holds it in none
    /// of them (see `TerminalZoomSizeLock.borrowFocus(pid:to:)` for what was
    /// measured). Zooming a window of some *other* app would therefore mean
    /// activating that app mid-scroll, a far bigger thing than this gesture is
    /// allowed to do — so a Chrome window laid over a terminal, or the other
    /// terminal app's window, falls back to the keyboard's own window exactly as
    /// before.
    static func choose(point: CGPoint,
                       windows: [ZoomWindowInfo],
                       frontmostTerminalPid: pid_t?) -> TerminalZoomChoice {
        guard let pid = frontmostTerminalPid else { return .none }
        if let hit = windowUnderMouse(point, in: windows), hit.pid == pid {
            return .windowUnderMouse(pid: pid, bounds: hit.bounds)
        }
        return .focusedWindow(pid: pid)
    }

    /// The window server and the Accessibility API describe the same window in
    /// the same global, top-left-origin coordinates, so matching one against the
    /// other only has to absorb rounding.
    static let boundsTolerance: CGFloat = 2

    static func sameWindow(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= boundsTolerance && abs(a.origin.y - b.origin.y) <= boundsTolerance
            && abs(a.width - b.width) <= boundsTolerance && abs(a.height - b.height) <= boundsTolerance
    }
}

/// A zoom target resolved down to something that can actually be driven.
struct TerminalZoomTarget {
    let pid: pid_t
    let window: AXUIElement
}

/// Impure half: reads the window list and the Accessibility tree.
enum TerminalZoomTargeting {

    /// Every on-screen window, front to back. One local call — it asks the window
    /// server, not the owning applications, so a hung app cannot slow it down.
    static func onScreenWindows() -> [ZoomWindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary) else {
                return nil
            }
            return ZoomWindowInfo(pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// The window a zoom step should act on: the one under the pointer when that
    /// is a window of the active terminal, otherwise the one holding the keyboard.
    static func resolve(mouse: CGPoint, frontmostTerminalPid: pid_t?) -> TerminalZoomTarget? {
        switch TerminalZoomTargetPolicy.choose(point: mouse,
                                               windows: onScreenWindows(),
                                               frontmostTerminalPid: frontmostTerminalPid) {
        case .none:
            return nil
        case .focusedWindow(let pid):
            return focusedTarget(pid: pid)
        case .windowUnderMouse(let pid, let bounds):
            // Try the focused window first: it is both the common case (the
            // pointer usually rests over the terminal being typed in) and one
            // round trip instead of two per window.
            if let focused = AXWindows.focusedWindow(pid: pid),
               let frame = AXWindows.frame(of: focused),
               TerminalZoomTargetPolicy.sameWindow(frame, bounds) {
                return TerminalZoomTarget(pid: pid, window: focused)
            }
            for window in AXWindows.windows(pid: pid) {
                if let frame = AXWindows.frame(of: window),
                   TerminalZoomTargetPolicy.sameWindow(frame, bounds) {
                    return TerminalZoomTarget(pid: pid, window: window)
                }
            }
            // The window server sees a window the Accessibility tree does not
            // (a sheet, a full-screen tile, something exotic). Zooming the
            // keyboard's window is a better answer than zooming nothing.
            return focusedTarget(pid: pid)
        }
    }

    private static func focusedTarget(pid: pid_t) -> TerminalZoomTarget? {
        guard let window = AXWindows.focusedWindow(pid: pid) else { return nil }
        return TerminalZoomTarget(pid: pid, window: window)
    }
}
