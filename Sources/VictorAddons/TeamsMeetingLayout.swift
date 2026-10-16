import AppKit
import ApplicationServices

/// 🎥 **Layout Teams** — the Microsoft Teams twin of `ZoomMeetingLayout`, behind
/// the same menu row: a running Teams meeting onto the monitor above the Retina
/// the way Victor watches a session (2026-10-16, copied off the layout he had
/// set by hand): the meeting window **filling that screen**, the **meeting chat
/// docked on the right** inside it, and the stage on **Gallery** at **9 people**.
///
/// Simpler than Zoom in geometry — Teams docks its chat inside the meeting
/// window, so there is one window to place and no column to compute — and
/// harder in reach: new Teams (`com.microsoft.teams2`) is a Chromium web view,
/// and everything after the window frame is a web button found by its
/// **DOM id** (`AXDOMIdentifier`), which does not change with the language or
/// with the Show/Hide wording:
///
/// ```
/// AXWindow Subrole=AXStandardWindow  Title="<meeting> | <org> | Microsoft Teams"
///   AXButton      dom=hangup-button           ← proves it is the meeting window
///   AXButton      dom=chat-button             ← toggles the docked chat pane
///   AXGroup       dom=message-pane-layout-a11y ← the chat pane, when open
///   AXPopUpButton dom=view-mode-button        → AXMenu
///     AXMenuItem  dom=custom-view-button-MixedGridButton  "Gallery"  v=1 when on
///     AXMenuItem  dom=gallery-view-size-button            "Gallery size" → AXMenu
///       AXMenuItem dom=gallery-view-size-button-9         "9 people" v=1 when on
/// ```
///
/// Chromium builds that tree only for a client that asks: until something sets
/// `AXEnhancedUserInterface` on the app, the web view is one empty group. The
/// flag is raised only for the button work and put back as it was afterwards,
/// and it is **off** while the frame is written — with it on, Chromium answers
/// each frame write relative to where the window was before the batch, so a
/// window moved across screens bounces back (`AXWindows.setFrame`, 2026-10-16).
final class TeamsMeetingLayout {

    static let bundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]

    struct Report {
        var outcome: ZoomMeetingLayout.Outcome
        var display: CGRect?
        var meeting: CGRect?
        var chatOpen = false
        var gallery9 = false
        var notes: [String] = []

        var json: String {
            func r(_ rect: CGRect?) -> String {
                guard let rect else { return "null" }
                return "[\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))]"
            }
            let n = notes.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ",")
            return "{\"app\":\"teams\",\"outcome\":\"\(outcome.rawValue)\",\"display\":\(r(display)),"
                + "\"meeting\":\(r(meeting)),\"chatOpen\":\(chatOpen),\"gallery9\":\(gallery9),\"notes\":[\(n)]}"
        }
    }

    private static let tolerance: CGFloat = 6
    private static let enhancedUI = "AXEnhancedUserInterface" as CFString

    static func runningApp() -> NSRunningApplication? {
        bundleIDs.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
    }

    /// **Call off the main thread** — waits on Teams for up to a few seconds
    /// at each step.
    static func apply() -> Report {
        guard let app = runningApp() else { return Report(outcome: .zoomNotRunning) }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        let wasEnhanced = boolAttr(axApp, enhancedUI as String) == true
        AXUIElementSetAttributeValue(axApp, enhancedUI, kCFBooleanTrue)
        defer { AXUIElementSetAttributeValue(axApp, enhancedUI, wasEnhanced ? kCFBooleanTrue : kCFBooleanFalse) }

        // The web tree takes a moment to appear the first time it is asked for.
        var meeting: AXUIElement?
        for attempt in 0..<20 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            meeting = meetingWindow(axApp)
            if meeting != nil { break }
        }
        guard let meeting else { return Report(outcome: .noMeeting) }
        guard let display = ZoomMeetingLayout.displayAboveBuiltIn(),
              let usable = ZoomMeetingLayout.onMain({ ZoomMeetingLayout.usableArea(ofDisplayBounds: display) }) else {
            return Report(outcome: .noDisplayAbove)
        }
        var report = Report(outcome: .done, display: display)

        if boolAttr(meeting, "AXFullScreen") == true {
            AXUIElementSetAttributeValue(meeting, "AXFullScreen" as CFString, kCFBooleanFalse)
            report.notes.append("left fullscreen")
            Thread.sleep(forTimeInterval: 1.5)
        }

        AXUIElementSetAttributeValue(axApp, enhancedUI, kCFBooleanFalse)
        place(meeting, usable)
        AXUIElementSetAttributeValue(axApp, enhancedUI, kCFBooleanTrue)
        report.meeting = AXWindows.frame(of: meeting)

        app.activate()
        AXUIElementPerformAction(meeting, kAXRaiseAction as CFString)
        // The tree answers reads at once, but presses are ignored for about a
        // second after the flag goes up: measured, View pressed 0.5 s after it
        // never opened its menu, pressed 1 s after it opened in 1.5 s.
        Thread.sleep(forTimeInterval: 1.5)

        report.chatOpen = ensureChat(meeting, notes: &report.notes)
        report.gallery9 = ensureGallery9(meeting, notes: &report.notes)

        // A title bar cannot go under the menu bar, so a usable area that was
        // too optimistic about its top edge costs height, not correctness.
        let landed = report.meeting.map { got in
            abs(got.minX - usable.minX) <= tolerance && abs(got.width - usable.width) <= tolerance
                && abs(got.maxY - usable.maxY) <= tolerance && got.minY >= usable.minY - tolerance
        } ?? false
        if !landed { report.notes.append("off target") }
        if !landed || !report.chatOpen || !report.gallery9 { report.outcome = .misplaced }
        return report
    }

    // MARK: - Steps

    /// The `AXStandardWindow` with a Leave button. Not by title: Teams also
    /// opens an `AXSystemDialog` carrying the meeting's title, plus the sharing
    /// control bar.
    private static func meetingWindow(_ axApp: AXUIElement) -> AXUIElement? {
        windows(axApp)
            .filter { stringAttr($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
            .first { find(in: $0, dom: "hangup-button") != nil }
    }

    /// Move → resize → move, like Zoom's: the window may start on another
    /// display, where a size bigger than that display would be clamped.
    private static func place(_ window: AXUIElement, _ rect: CGRect) {
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            var origin = rect.origin
            var size = rect.size
            guard let o = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, o)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, o)
            if let got = AXWindows.frame(of: window),
               abs(got.minX - rect.minX) <= tolerance, abs(got.maxY - rect.maxY) <= tolerance,
               abs(got.width - rect.width) <= tolerance { return }
        }
    }

    /// `chat-button` is a toggle, so it is pressed only when the pane is not
    /// there — blind, it would close the chat Victor already has open.
    private static func ensureChat(_ meeting: AXUIElement, notes: inout [String]) -> Bool {
        if find(in: meeting, dom: "message-pane-layout-a11y") != nil { return true }
        guard let button = find(in: meeting, dom: "chat-button") else {
            notes.append("no chat button")
            return false
        }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        notes.append("opened chat")
        if waitFor(in: meeting, dom: "message-pane-layout-a11y") != nil { return true }
        notes.append("chat did not open")
        return false
    }

    /// View → Gallery, then View → Gallery size → 9 people. Each item is
    /// pressed only when its `AXValue` says it is not already the one on.
    /// The submenu is gone again within a couple of seconds, so it is reached
    /// with the references in hand rather than by searching the whole tree.
    private static func ensureGallery9(_ meeting: AXUIElement, notes: inout [String]) -> Bool {
        guard let gallery = openViewMenu(meeting, item: "custom-view-button-MixedGridButton", notes: &notes) else {
            return false
        }
        if !isOn(gallery) {
            AXUIElementPerformAction(gallery, kAXPressAction as CFString)
            notes.append("gallery on")
            Thread.sleep(forTimeInterval: 0.8)
        }
        guard let size = find(in: meeting, dom: "gallery-view-size-button")
                ?? openViewMenu(meeting, item: "gallery-view-size-button", notes: &notes) else {
            return false
        }
        AXUIElementPerformAction(size, kAXPressAction as CFString)
        guard let nine = waitFor(in: meeting, dom: "gallery-view-size-button-9") else {
            notes.append("no 9-people item")
            closeMenus(meeting)
            return false
        }
        // Pressed even when already on: choosing the checked item is the one
        // thing measured to close the menu (`AXCancel` on its items leaves it open).
        if !isOn(nine) { notes.append("9 people") }
        AXUIElementPerformAction(nine, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.5)
        closeMenus(meeting)
        return true
    }

    /// Presses View (unless its menu is already open) and returns `item` from it.
    private static func openViewMenu(_ meeting: AXUIElement, item dom: String,
                                     notes: inout [String]) -> AXUIElement? {
        if let open = find(in: meeting, dom: dom) { return open }
        guard let view = find(in: meeting, dom: "view-mode-button") else {
            notes.append("no view button")
            return nil
        }
        AXUIElementPerformAction(view, kAXPressAction as CFString)
        if let item = waitFor(in: meeting, dom: dom) { return item }
        notes.append("view menu did not open")
        return nil
    }

    /// Never leave the View menu hanging open on the call: if any of it is
    /// still there, View is pressed once more, which toggles it shut.
    private static func closeMenus(_ meeting: AXUIElement) {
        guard find(in: meeting, dom: "gallery-view-size-button") != nil,
              let view = find(in: meeting, dom: "view-mode-button") else { return }
        AXUIElementPerformAction(view, kAXPressAction as CFString)
    }

    private static func isOn(_ item: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXValueAttribute as CFString, &raw) == .success else { return false }
        if let n = raw as? NSNumber { return n.boolValue }
        return (raw as? String) == "1"
    }

    // MARK: - AX plumbing

    private static func waitFor(in root: AXUIElement, dom: String, seconds: Double = 4) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let hit = find(in: root, dom: dom) { return hit }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return nil
    }

    /// Breadth-first, so the toolbar and the menus — a dozen levels down — are
    /// reached before the video tiles, which sit deeper and are most of the tree.
    private static func find(in root: AXUIElement, dom: String) -> AXUIElement? {
        var level = [root]
        for _ in 0..<40 where !level.isEmpty {
            var next: [AXUIElement] = []
            for el in level {
                if stringAttr(el, "AXDOMIdentifier") == dom { return el }
                next.append(contentsOf: children(el))
            }
            level = next
        }
        return nil
    }

    private static func windows(_ axApp: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw) == .success else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    private static func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func boolAttr(_ el: AXUIElement, _ name: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &raw) == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }
}
