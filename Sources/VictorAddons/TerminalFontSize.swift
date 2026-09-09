import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// How big the text in a terminal window actually is, and how far Cmd+scroll is
/// allowed to take it.
///
/// **The obvious source does not work.** Terminal.app's AppleScript
/// `font size of window` reports the *profile's* size and never moves when
/// View ▸ Bigger/Smaller changes the live one — measured 2026-09-09, a window
/// visibly at 23 pt still answered `18`, the same as every untouched window
/// beside it. (Reading it also means Automation consent, which this gesture has
/// never needed.)
///
/// What does move is the **character cell**, and Accessibility hands it over
/// exactly: `AXBoundsForRange` on the window's `AXTextArea` for the first
/// character returns that one cell's box. Measured the same day on Victor's
/// profile: `11×23` points at 18 pt, `14×28` at 23 pt — the same numbers the
/// grid gives when solved by hand (cell width and height as a function of point
/// size, from `number of columns`/`number of rows` at a known window width).
/// Same AX grant the rest of the gesture already uses, no Automation consent, no
/// subprocess.
///
/// **The limits are held in cell height, not point size**, because the cell is
/// what can be measured and the point size cannot: converting between them needs
/// the profile's font metrics, so a bound written in points would quietly mean
/// something else the day the font changes. Cell height *is* the visual size.
enum TerminalFontSize {

    /// The bounding box of one character cell, in points — the live size of the
    /// text, whatever the profile claims. `nil` when the window exposes no text
    /// area that answers (a terminal other than the two we know, a window still
    /// opening), and a `nil` never blocks a zoom step.
    static func cell(of window: AXUIElement) -> CGSize? {
        guard let area = textArea(in: window, depth: 0) else { return nil }
        return bounds(of: area, location: 0, length: 1)?.size
    }

    // MARK: - AX plumbing

    /// Terminal.app nests the text area under a scroll area under a split group;
    /// iTerm2 differs again, so this walks rather than assumes. Depth-capped so a
    /// window with a deep view tree cannot turn one scroll notch into a long walk
    /// on the event-tap thread.
    private static func textArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 5 else { return nil }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
              let children = kids as? [AXUIElement] else { return nil }
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXTextArea" { return child }
            if let found = textArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func bounds(of area: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            area, kAXBoundsForRangeParameterizedAttribute as CFString, param, &raw) == .success,
            let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}

/// Pure half of the zoom's limits: from the cell height under the pointer, which
/// of the two directions a scroll notch is still allowed to take.
enum TerminalZoomLimitsPolicy {

    /// Both bounds are the sizes Victor demonstrated on 2026-09-09 — the small
    /// one is where he stopped and said a smaller font makes no sense to allow,
    /// the big one where he said never bigger than that. On his profile they are
    /// 11 pt and 23 pt; measured off the two screenshots (character pitch 7×14
    /// and 14×28 points) and confirmed against a live window through
    /// `TerminalFontSize.cell`.
    static let minCellHeight: CGFloat = 14
    static let maxCellHeight: CGFloat = 28

    /// Half a font step of slack. A cell height is reported as a whole number of
    /// points and a font step moves it by ~1.28, so anything within half a point
    /// of a bound *is* that bound.
    static let epsilon: CGFloat = 0.5

    struct Allowed: Equatable {
        var smaller: Bool
        var bigger: Bool

        /// What an unmeasurable window gets. A terminal we cannot read must keep
        /// zooming exactly as it did before this existed — a limit that fires
        /// because a measurement failed is worse than no limit.
        static let unrestricted = Allowed(smaller: true, bigger: true)
    }

    /// - Parameter cellHeight: the height of one character cell right now, or
    ///   `nil` if it could not be read.
    ///
    /// The test is on the size the window is at, not on the one a step would
    /// reach: a window sitting *at* the floor refuses to shrink, one a step above
    /// it shrinks onto the floor and stops there. That makes both bounds
    /// reachable and neither passable.
    static func allowed(cellHeight: CGFloat?) -> Allowed {
        guard let cellHeight else { return .unrestricted }
        return Allowed(smaller: cellHeight > minCellHeight + epsilon,
                       bigger: cellHeight < maxCellHeight - epsilon)
    }
}

/// Thin wrapper behind `GET /test/terminal-font`: what the zoom sees, for every
/// window of the front terminal — the cell it measured and the two directions it
/// would still allow. Checking a limit by scrolling means being at the machine;
/// this is the headless version.
enum TerminalFontSizeProbe {
    static func json() -> String {
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.Terminal" })?.processIdentifier else {
            return "{\"error\":\"Terminal not running\"}"
        }
        let rows = AXWindows.windows(pid: pid).map { window -> String in
            let title = AXWindows.title(of: window) ?? "?"
            let cell = TerminalFontSize.cell(of: window)
            let allowed = TerminalZoomLimitsPolicy.allowed(cellHeight: cell?.height)
            let cellText = cell.map { "\($0.width)x\($0.height)" } ?? "null"
            return """
            {"title":"\(escape(title))","cell":"\(cellText)",\
            "canShrink":\(allowed.smaller),"canGrow":\(allowed.bigger)}
            """
        }
        return "[\(rows.joined(separator: ","))]"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
