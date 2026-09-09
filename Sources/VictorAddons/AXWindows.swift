import ApplicationServices
import CoreGraphics
import Foundation

/// The handful of Accessibility calls the Cmd+scroll terminal zoom needs, with
/// one cached application element per pid.
///
/// Every one of these can be called **from the event-tap thread** — the zoom has
/// to know which window it is about to change before the keystroke goes out — so
/// the short messaging timeout is the load-bearing part: an AX round trip into a
/// wedged terminal must never stall the tap long enough for the system to tear
/// it down. Same grant `TerminalTiler` already relies on; no Automation consent,
/// no subprocess.
enum AXWindows {

    /// Cap on a single AX round trip. The system default is measured in seconds,
    /// which on the tap thread is a hang.
    static let messagingTimeout: Float = 0.1

    private static let lock = NSLock()
    private static var appElements: [pid_t: AXUIElement] = [:]

    static func app(pid: pid_t) -> AXUIElement {
        lock.lock(); defer { lock.unlock() }
        if let el = appElements[pid] { return el }
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        appElements[pid] = el
        return el
    }

    /// The window that currently owns the keyboard inside `pid` — the one a
    /// menu-equivalent keystroke will land in.
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid: pid),
                                            kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Every window of `pid`, front to back.
    static func windows(pid: pid_t) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid: pid),
                                            kAXWindowsAttribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else {
            return []
        }
        return list
    }

    /// Hand a window the keyboard **within its own application**. Main is set
    /// before focused because that is the pair a click sets, and the one that was
    /// measured to work; either alone is not reliably enough for a terminal to
    /// aim its font commands at the window.
    ///
    /// This does nothing at all when the application is not active — see the
    /// note on `TerminalZoomSizeLock.borrowFocus(pid:to:)`.
    static func focus(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// A window's title, for the `/test/terminal-font` readout only — nothing in
    /// the gesture itself identifies a window by name.
    static func title(of window: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &raw) == .success else {
            return nil
        }
        return raw as? String
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let pos = value(of: window, kAXPositionAttribute, type: .cgPoint, as: CGPoint.self),
              let size = value(of: window, kAXSizeAttribute, type: .cgSize, as: CGSize.self) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var size = rect.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        // Position after size: a window pinned near a screen edge can be nudged by
        // the resize, and the origin is the half we can restore exactly.
        var origin = rect.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    static func value<T>(of el: AXUIElement, _ attr: String,
                                 type: AXValueType, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(value as! AXValue, type, out) else { return nil }
        return out.pointee
    }
}
