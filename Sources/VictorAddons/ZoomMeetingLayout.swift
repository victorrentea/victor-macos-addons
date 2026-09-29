import AppKit
import ApplicationServices

/// Pure geometry for 🎥 Layout Zoom — no Quartz, no Accessibility, so it is
/// unit-tested headless. Every rectangle is in **global top-left coordinates**
/// (y grows downwards, the primary display's top-left is 0,0), which is what
/// both `CGDisplayBounds` and Accessibility's `AXPosition` speak — so a display
/// above the primary has a *negative* y.
enum ZoomMeetingLayoutPolicy {

    /// The right-hand column that holds Participants over Chat. 360 pt is what
    /// Victor had set up by hand on 2026-09-29 (Participants 350, chat 360) —
    /// wide enough for a name + mic/camera icons, and for a chat line to wrap
    /// at a readable length.
    static let columnWidth: CGFloat = 360
    /// Chat's share of the column's height, bottom part. Also from the hand-made
    /// layout (378 of 1055): enough for four or five messages while Participants
    /// keeps room for ~10 rows.
    static let chatHeightFraction: CGFloat = 0.36

    struct Frames: Equatable {
        let meeting: CGRect
        let participants: CGRect
        let chat: CGRect
    }

    /// The display sitting on top of the built-in one — the monitor Victor
    /// keeps Zoom on. "On top" means its bottom edge touches (within a few
    /// points) the built-in's top edge and the two overlap horizontally; if
    /// several qualify the one with the widest overlap wins.
    static func displayAbove(_ builtIn: CGRect, among others: [CGRect]) -> CGRect? {
        let tolerance: CGFloat = 4
        return others
            .filter { abs($0.maxY - builtIn.minY) <= tolerance }
            .map { ($0, min($0.maxX, builtIn.maxX) - max($0.minX, builtIn.minX)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Meeting video on the left, taking everything but the column; the
    /// column split Participants (top) / Chat (bottom). All rounded to whole
    /// points, because Zoom rounds anyway and a half-point gap between the two
    /// panels shows as a hairline of desktop.
    static func frames(in usable: CGRect) -> Frames {
        let column = min(columnWidth, (usable.width * 0.3).rounded())
        let chatHeight = (usable.height * chatHeightFraction).rounded()
        let columnX = usable.maxX - column
        return Frames(
            meeting: CGRect(x: usable.minX, y: usable.minY,
                            width: usable.width - column, height: usable.height),
            participants: CGRect(x: columnX, y: usable.minY,
                                 width: column, height: usable.height - chatHeight),
            chat: CGRect(x: columnX, y: usable.maxY - chatHeight,
                         width: column, height: chatHeight))
    }
}

/// 🎥 **Layout Zoom** — one menu row that puts a running Zoom meeting onto the
/// monitor above the Retina the way Victor wants to *watch* a session: the
/// meeting video filling the left of the screen (who is speaking), and a
/// right-hand column with **Participants** on top and the **meeting chat** at
/// the bottom, so a question typed by someone on the call is never more than a
/// glance away.
///
/// Driven like `ZoomSharePrep` and `ZoomJoinAutoStart`, for their reasons:
/// in-process `AXUIElement` on this app's own Accessibility grant, no
/// `osascript`. Zoom Workplace 6.6 exposes everything needed:
///
/// ```
/// AXWindow Subrole=AXStandardWindow Title="Zoom Meeting"      ← the video
/// AXWindow Subrole=AXSystemDialog  Title="Participants (24)"  ← popped out
/// AXWindow Subrole=AXSystemDialog  Title="Meeting chat"       ← popped out
/// menu View → AXMenuItem id=onManageParticipants  "Show/Close participants"
/// menu View → AXMenuItem id=onChat               "Show/Close chat"
/// ```
///
/// The two panels are only placeable as their **own** windows. A panel that is
/// closed is opened through the View menu (by identifier, which does not change
/// with the Show/Close wording); one that is docked inside the meeting window
/// is popped out by its "Pop out" button.
final class ZoomMeetingLayout {

    enum Outcome: String {
        case done
        case zoomNotRunning = "zoom-not-running"
        case noMeeting = "no-meeting"
        case noDisplayAbove = "no-display-above"
        /// Frames were set but did not read back where they were aimed.
        case misplaced
    }

    struct Report {
        var outcome: Outcome
        var display: CGRect?
        var meeting: CGRect?
        var participants: CGRect?
        var chat: CGRect?
        var notes: [String] = []

        var json: String {
            func r(_ rect: CGRect?) -> String {
                guard let rect else { return "null" }
                return "[\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))]"
            }
            let n = notes.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }.joined(separator: ",")
            return "{\"outcome\":\"\(outcome.rawValue)\",\"display\":\(r(display)),\"meeting\":\(r(meeting)),"
                + "\"participants\":\(r(participants)),\"chat\":\(r(chat)),\"notes\":[\(n)]}"
        }
    }

    private static let zoomBundleID = "us.zoom.xos"
    private static let meetingTitles = ["Zoom Meeting", "Zoom Webinar"]
    private static let participantsPrefix = "Participants"
    private static let chatPrefix = "Meeting chat"
    private static let participantsMenuID = "onManageParticipants"
    private static let chatMenuID = "onChat"
    /// Tolerance for "the frame landed where aimed". Zoom enforces minimum
    /// panel sizes and rounds, so a couple of points is noise, not a miss.
    private static let tolerance: CGFloat = 6

    /// Runs the whole thing. **Call off the main thread** — it waits up to a few
    /// seconds for Zoom to open panels; the one `NSScreen` read it needs hops
    /// to main by itself.
    static func apply() -> Report {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: zoomBundleID).first else {
            return Report(outcome: .zoomNotRunning)
        }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        // Zoom's main thread blocks for seconds while it reconnects; never let
        // that hang the caller.
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        guard let meeting = window(of: axApp, where: { meetingTitles.contains($0) }) else {
            return Report(outcome: .noMeeting)
        }
        guard let display = displayAboveBuiltIn(),
              var usable = onMain({ usableArea(ofDisplayBounds: display) }) else {
            return Report(outcome: .noDisplayAbove)
        }
        var report = Report(outcome: .done, display: display)

        // A full-screen meeting window ignores AXPosition/AXSize.
        if boolAttr(meeting, "AXFullScreen") == true {
            AXUIElementSetAttributeValue(meeting, "AXFullScreen" as CFString, kCFBooleanFalse)
            report.notes.append("left fullscreen")
            Thread.sleep(forTimeInterval: 1.5)
        }

        let participants = ensurePanel(axApp: axApp, meeting: meeting, prefix: participantsPrefix,
                                       menuID: participantsMenuID, popOutHint: "participant", notes: &report.notes)
        let chat = ensurePanel(axApp: axApp, meeting: meeting, prefix: chatPrefix,
                               menuID: chatMenuID, popOutHint: "chat", notes: &report.notes)

        // Meeting first: macOS keeps a window's title bar below the menu bar,
        // so if `usable` was too optimistic about the top edge the meeting
        // window says so, and the column is laid out from where it really is.
        var frames = ZoomMeetingLayoutPolicy.frames(in: usable)
        AXWindows.setFrame(meeting, frames.meeting)
        if let got = AXWindows.frame(of: meeting), got.minY > usable.minY + 1 {
            let shift = got.minY - usable.minY
            usable = CGRect(x: usable.minX, y: got.minY, width: usable.width, height: usable.height - shift)
            report.notes.append("top pushed down \(Int(shift))pt")
            frames = ZoomMeetingLayoutPolicy.frames(in: usable)
            AXWindows.setFrame(meeting, frames.meeting)
        }
        if let participants { AXWindows.setFrame(participants, frames.participants) }
        if let chat { AXWindows.setFrame(chat, frames.chat) }

        // Bring the three up together, panels last so they sit over the video
        // window's edge rather than under it.
        app.activate()
        for w in [meeting, participants, chat].compactMap({ $0 }) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }

        report.meeting = AXWindows.frame(of: meeting)
        report.participants = participants.flatMap(AXWindows.frame(of:))
        report.chat = chat.flatMap(AXWindows.frame(of:))

        let misses = [(report.meeting, frames.meeting, "meeting"),
                      (report.participants, participants == nil ? nil : frames.participants, "participants"),
                      (report.chat, chat == nil ? nil : frames.chat, "chat")]
            .filter { got, want, _ in want != nil && !close(got, want!) }
            .map { $0.2 }
        if !misses.isEmpty || participants == nil || chat == nil {
            report.outcome = .misplaced
            if !misses.isEmpty { report.notes.append("off target: " + misses.joined(separator: ",")) }
        }
        return report
    }

    // MARK: - Panels

    /// The panel as its own window: already there → it; closed → opened from
    /// the View menu; docked in the meeting window → popped out.
    private static func ensurePanel(axApp: AXUIElement, meeting: AXUIElement, prefix: String,
                                    menuID: String, popOutHint: String,
                                    notes: inout [String]) -> AXUIElement? {
        if let w = window(of: axApp, where: { $0.hasPrefix(prefix) }) { return w }

        // Closed (menu reads "Show …") → open it. Zoom reopens a panel the
        // way it was last shown, popped out or docked.
        if let item = menuItem(of: axApp, identifier: menuID),
           let title = stringAttr(item, kAXTitleAttribute), !title.lowercased().hasPrefix("close") {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            notes.append("opened \(popOutHint)")
            if let w = waitForWindow(axApp, prefix: prefix) { return w }
        }

        // Docked → its "Pop out" button, somewhere in the meeting window.
        if let button = findButton(in: meeting, depth: 0, matching: { d in
            let l = d.lowercased()
            return l.contains("pop out") && (l.contains(popOutHint) || !l.contains("participant") && !l.contains("chat"))
        }) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            notes.append("popped out \(popOutHint)")
            if let w = waitForWindow(axApp, prefix: prefix) { return w }
        }
        notes.append("no \(popOutHint) window")
        return nil
    }

    private static func waitForWindow(_ axApp: AXUIElement, prefix: String) -> AXUIElement? {
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.2)
            if let w = window(of: axApp, where: { $0.hasPrefix(prefix) }) { return w }
        }
        return nil
    }

    // MARK: - AX plumbing

    private static func window(of axApp: AXUIElement, where match: (String) -> Bool) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return nil }
        return windows.first { stringAttr($0, kAXTitleAttribute).map(match) ?? false }
    }

    private static func menuItem(of axApp: AXUIElement, identifier: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &raw) == .success,
              let bar = raw else { return nil }
        // Menu bar → bar item → AXMenu → items. Three levels, no deeper.
        for top in children(bar as! AXUIElement) {
            for menu in children(top) {
                for item in children(menu) where stringAttr(item, "AXIdentifier") == identifier {
                    return item
                }
            }
        }
        return nil
    }

    private static func findButton(in el: AXUIElement, depth: Int,
                                   matching: (String) -> Bool) -> AXUIElement? {
        if depth > 8 { return nil }
        if stringAttr(el, kAXRoleAttribute) == kAXButtonRole as String {
            let label = [stringAttr(el, kAXDescriptionAttribute), stringAttr(el, kAXTitleAttribute),
                         stringAttr(el, kAXHelpAttribute)].compactMap { $0 }.joined(separator: " ")
            if matching(label) { return el }
        }
        for child in children(el) {
            if let hit = findButton(in: child, depth: depth + 1, matching: matching) { return hit }
        }
        return nil
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

    private static func close(_ got: CGRect?, _ want: CGRect) -> Bool {
        guard let got else { return false }
        return abs(got.minX - want.minX) <= tolerance && abs(got.minY - want.minY) <= tolerance
            && abs(got.width - want.width) <= tolerance && abs(got.height - want.height) <= tolerance
    }

    // MARK: - Displays

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private static func displayAboveBuiltIn() -> CGRect? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let online = ids.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        guard let builtIn = online.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        return ZoomMeetingLayoutPolicy.displayAbove(CGDisplayBounds(builtIn),
                                                    among: online.filter { $0 != builtIn }.map(CGDisplayBounds))
    }

    /// `NSScreen.visibleFrame` of the display with these global top-left
    /// bounds, converted back to top-left coordinates — the menu bar (and a
    /// Dock parked on that screen) taken out. **Main thread only.**
    private static func usableArea(ofDisplayBounds bounds: CGRect) -> CGRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let screen = NSScreen.screens.first { s in
            let f = s.frame
            return abs(f.minX - bounds.minX) < 1 && abs((primaryHeight - f.maxY) - bounds.minY) < 1
        }
        guard let vf = screen?.visibleFrame else { return bounds }
        return CGRect(x: vf.minX, y: primaryHeight - vf.maxY, width: vf.width, height: vf.height)
    }
}
