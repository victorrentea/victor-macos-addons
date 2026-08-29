import AppKit
import ApplicationServices

/// 🔊 Prepares Zoom's screen-share picker the instant it opens: ticks **Share
/// sound**, selects the **presenter layout**, and drags Victor's **camera
/// cut-out** into the bottom-right third of the preview — so he never again
/// shares a demo the room can't hear, or spends the first minute of a session
/// dragging his own face into place while everyone watches.
///
/// **Why this exists.** Zoom resets all three at the start of every meeting.
/// "Share sound" is remembered only *within* one meeting; the presenter layout
/// likewise. There is no user preference and no `us.zoom.config` mass-deployment
/// key for either (`EnableShareAudio` only makes the option *available* — it does
/// not pre-tick it), and the client's own settings live in
/// `~/Library/Application Support/zoom.us/data/zoomus.enc.db`, a SQLCipher file.
/// So the state cannot be persisted from the outside; it has to be re-applied
/// each time the picker appears. Filed with Zoom as a feature request 2026-08-29.
///
/// **How.** The picker is a plain, fully-accessible AppKit window — verified by
/// dumping Zoom 6.6's AX tree:
///
/// ```
/// AXWindow Subrole=AXSystemDialog Title="Share screen window"
///   AXScrollArea
///     AXList Description="Choose a layout"
///       AXRadioButton Description="Choose a layout, Over the shoulder"
///         AXButton Title="Over the shoulder"          actions=[AXPress]
///     AXCheckBox Description="Share sound" Value=0/1  actions=[AXPress]
/// ```
///
/// Everything is driven **in-process through `AXUIElement`**, which needs only
/// this app's own Accessibility grant — the same one behind the global event tap
/// and `TerminalTiler`. Deliberately *not* `osascript` + "System Events": that
/// needs a separate Automation (Apple Events) grant which stops matching after
/// every re-sign, and it resolves Zoom's deeply nested hierarchy unreliably
/// (System Events could not even find the layout radio buttons by title).
///
/// **Trigger.** An `AXObserver` on `kAXWindowCreatedNotification` fires the
/// moment the picker opens; a 1.5 s safety poll covers the case where Zoom
/// reuses a window instead of creating one (the notification never arrives
/// then). Both funnel into one serial scan. The dialog's subtree populates
/// asynchronously, so each trigger runs a short retry ladder.
///
/// **Feedback is emoji-only, on purpose** — the same reasoning as
/// `SilentTranscriptionWarning`'s `😶😶😶`. When Victor re-opens the picker
/// during an ongoing share, the room is watching his screen; `🔊✅` reads as
/// innocuous, an English sentence about automation would not.
final class ZoomSharePrep {

    /// Zoom's share picker, as it identifies itself to Accessibility.
    private static let dialogTitle = "Share screen window"
    private static let shareSoundLabel = "Share sound"
    private static let layoutListLabel = "Choose a layout"
    private static let previewAreaLabel = "Presenter layout preview area"
    /// The cut-out's frame must keep the camera's own aspect, otherwise the
    /// 16:9 video is letterboxed inside it and leaves a gap under Victor's head
    /// instead of sitting on the bottom edge. Zoom's own default frame is
    /// 124×70 = 1.771, i.e. 16:9 — we simply hold that ratio while shrinking.
    private static let cutoutAspect: CGFloat = 16.0 / 9.0
    private static let maxPlacementPasses = 3
    private static let zoomBundleID = "us.zoom.xos"

    /// Zoom's four presenter layouts, exactly as their buttons are titled.
    /// The two that composite Victor's camera **over** the shared content — what
    /// the participants actually see — are `asBackground` (the one he uses: the
    /// shared screen becomes the backdrop and he is cut out over it, bottom-right)
    /// and `overTheShoulder`.
    enum PresenterLayout: String, CaseIterable {
        case contentOnly = "Content only"
        case asBackground = "As background"
        case overTheShoulder = "Over the shoulder"
        case sideBySide = "Side by side"

        /// The two layouts that composite the camera over the content, i.e. the
        /// ones where a draggable cut-out exists at all.
        var hasCameraCutout: Bool { self == .asBackground || self == .overTheShoulder }
    }

    /// Set to nil to leave the layout alone and only handle the sound checkbox.
    var presenterLayout: PresenterLayout? = .asBackground
    var isEnabled = true

    /// Where Victor's camera cut-out should sit inside the presenter-layout
    /// preview: flush to the right and bottom edges, a third of the width.
    /// Set to nil to place the layout but leave the cut-out wherever Zoom put it.
    var cutoutWidthFraction: CGFloat? = 1.0 / 3.0

    /// Shows the 🔊✅ / 🔊❌ confirmation. Injected so tests can run headless.
    var onResult: ((Result) -> Void)?

    struct Result {
        let soundWasAlreadyOn: Bool
        let soundOnNow: Bool
        let layoutApplied: PresenterLayout?
        /// nil when placement wasn't attempted; false when it was and missed.
        let cutoutPlaced: Bool?
    }

    // MARK: - Lifecycle

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.zoom-share-prep",
                                      qos: .userInitiated)
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var safetyTimer: DispatchSourceTimer?
    /// Rising-edge guard: sound + layout are applied once per appearance.
    private var dialogWasOpen = false
    /// Placement is retried across scans — unlike the two presses, it can be
    /// skipped for a reason that clears by itself (Victor still holding the
    /// mouse button from the click that opened the picker). Capped so a layout
    /// whose cut-out simply won't sit where we want doesn't drag forever.
    private var placementAttempts = 0
    private var placementDone = false
    private static let maxPlacementAttempts = 4

    func start() {
        attachToZoomIfRunning()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.zoomBundleID else { return }
            self?.attachToZoomIfRunning()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.zoomBundleID else { return }
            self?.detach()
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 1.5)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        safetyTimer = t
    }

    deinit {
        safetyTimer?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private static func zoomApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: zoomBundleID).first
    }

    private func attachToZoomIfRunning() {
        guard let app = Self.zoomApp() else { return }
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        detach()

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<ZoomSharePrep>.fromOpaque(refcon).takeUnretainedValue()
            me.scanSoon()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }

        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Window-created is the fast path; focus changes catch a reused window.
        for note in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(obs, appEl, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
        overlayInfo("ZoomSharePrep: watching Zoom (pid \(pid))")
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        dialogWasOpen = false
    }

    // MARK: - Scanning

    /// The picker's subtree fills in asynchronously — a scan fired the instant
    /// the window is created usually finds an empty shell. Retry a few times,
    /// then let the safety poll take over.
    private func scanSoon() {
        for delay in [0.05, 0.2, 0.5, 1.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
        }
    }

    private func scan() {
        guard isEnabled, let app = Self.zoomApp() else {
            dialogWasOpen = false
            return
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // Zoom can block on its own main thread mid-meeting; never let an AX call
        // wedge our queue behind it.
        AXUIElementSetMessagingTimeout(appEl, 1.0)

        guard let dialog = Self.shareDialog(in: appEl) else {
            dialogWasOpen = false
            placementAttempts = 0
            placementDone = false
            return
        }
        if dialogWasOpen {
            // Sound + layout are done; the cut-out may still need another go.
            retryPlacementIfNeeded(in: dialog)
            return
        }

        guard let checkbox = Self.find(in: dialog, role: kAXCheckBoxRole,
                                       description: Self.shareSoundLabel) else {
            return  // subtree not populated yet — a later retry will find it
        }
        dialogWasOpen = true

        let wasOn = Self.isChecked(checkbox)
        if !wasOn {
            AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
        }
        // Zoom applies the toggle asynchronously; give it a beat, then verify —
        // and press once more if the first press didn't land.
        usleep(120_000)
        var onNow = Self.isChecked(checkbox)
        if !onNow {
            AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
            usleep(120_000)
            onNow = Self.isChecked(checkbox)
        }

        var appliedLayout: PresenterLayout?
        if let wanted = presenterLayout, Self.selectLayout(wanted, in: dialog) {
            appliedLayout = wanted
        }

        var placed: Bool?
        if wantsPlacement {
            placementAttempts += 1
            placed = Self.placeCutout(in: dialog, widthFraction: cutoutWidthFraction!)
            placementDone = placed == true
        }

        let result = Result(soundWasAlreadyOn: wasOn, soundOnNow: onNow,
                            layoutApplied: appliedLayout, cutoutPlaced: placed)
        overlayInfo("ZoomSharePrep: share sound \(wasOn ? "already on" : (onNow ? "ticked" : "FAILED to tick"))"
                    + (appliedLayout.map { ", layout → \($0.rawValue)" } ?? "")
                    + (placed.map { ", cut-out \($0 ? "placed" : "NOT placed")" } ?? ""))
        DispatchQueue.main.async { [weak self] in self?.onResult?(result) }
    }

    /// True when a camera cut-out exists to place at all — only the two layouts
    /// that composite the camera over the content have one.
    private var wantsPlacement: Bool {
        guard cutoutWidthFraction != nil, let layout = presenterLayout else { return false }
        return layout.hasCameraCutout
    }

    /// The picker is already prepared, but the cut-out isn't where we want it —
    /// most often because the first attempt landed while the mouse button was
    /// still down from the click that opened the picker. Runs off the safety
    /// poll, so the retries are naturally spaced ~1.5 s apart.
    private func retryPlacementIfNeeded(in dialog: AXUIElement) {
        guard wantsPlacement, !placementDone,
              placementAttempts < Self.maxPlacementAttempts else { return }
        placementAttempts += 1
        if Self.placeCutout(in: dialog, widthFraction: cutoutWidthFraction!) {
            placementDone = true
            overlayInfo("ZoomSharePrep: cut-out placed on attempt \(placementAttempts)")
        }
    }

    /// `GET /test/zoom-share` — reports what the scanner can see right now and
    /// re-arms it, so the picker can be re-prepared without closing and
    /// re-opening it by hand. See docs/testing.md.
    func testSnapshotJSON() -> String {
        guard let app = Self.zoomApp() else {
            return #"{"zoomRunning":false}"#
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        let dialog = Self.shareDialog(in: appEl)
        let checkbox = dialog.flatMap {
            Self.find(in: $0, role: kAXCheckBoxRole, description: Self.shareSoundLabel)
        }
        let snapshot = """
        {"zoomRunning":true,"enabled":\(isEnabled),"dialogOpen":\(dialog != nil),\
        "shareSoundFound":\(checkbox != nil),\
        "shareSoundOn":\(checkbox.map { Self.isChecked($0) } ?? false),\
        "presenterLayout":\(presenterLayout.map { "\"\($0.rawValue)\"" } ?? "null")}
        """
        queue.async { [weak self] in
            self?.dialogWasOpen = false
            self?.placementAttempts = 0
            self?.placementDone = false
            self?.scan()
        }
        return snapshot
    }

    // MARK: - AX helpers

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func isChecked(_ el: AXUIElement) -> Bool {
        (attr(el, kAXValueAttribute) as? Int ?? 0) != 0
    }

    private static func shareDialog(in appEl: AXUIElement) -> AXUIElement? {
        let windows = attr(appEl, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { string($0, kAXTitleAttribute) == dialogTitle }
    }

    /// Depth-first search for the first descendant matching a role and an exact
    /// `AXDescription`. Zoom nests the picker's controls several scroll areas
    /// deep and gives them no `AXIdentifier`, so the description is the handle.
    private static func find(in root: AXUIElement,
                             role: String,
                             description: String,
                             depth: Int = 0) -> AXUIElement? {
        if depth > 20 { return nil }
        for child in children(root) {
            if string(child, kAXRoleAttribute) == role,
               string(child, kAXDescriptionAttribute) == description {
                return child
            }
            if let hit = find(in: child, role: role, description: description, depth: depth + 1) {
                return hit
            }
        }
        return nil
    }

    private static func findButton(in root: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
        if depth > 20 { return nil }
        for child in children(root) {
            if string(child, kAXRoleAttribute) == kAXButtonRole,
               string(child, kAXTitleAttribute) == title {
                return child
            }
            if let hit = findButton(in: child, title: title, depth: depth + 1) { return hit }
        }
        return nil
    }

    // MARK: - Placing the camera cut-out

    /// Drags Victor's camera cut-out to the **bottom-right corner** of the
    /// presenter-layout preview and narrows it to `widthFraction` of the
    /// preview's width.
    ///
    /// **Why a synthetic drag and not an attribute write.** The cut-out *is*
    /// exposed — `AXTabGroup Description="<his name>"` inside
    /// `Presenter layout preview area` — and its `AXPosition`/`AXSize` are
    /// readable, but both are **read-only**: `AXUIElementIsAttributeSettable`
    /// answers false and `AXUIElementSetAttributeValue` returns `-25200` while
    /// nothing moves (probed against Zoom 6.6 on 2026-08-29). The composited
    /// cut-out on the shared screen itself isn't an AX element at all — AX
    /// hit-testing the shared surface returns the *shared app* underneath. So
    /// the preview widget, driven by mouse events, is the only handle there is.
    ///
    /// Doing it **in the picker, before the share starts**, matters: the same
    /// widget exists in the floating `Presenter layout` window during a share,
    /// but by then the room is already watching the drag.
    ///
    /// The geometry is never assumed — every drag is followed by re-reading the
    /// frames, and up to `maxAttempts` passes run until the result is inside
    /// tolerance. Each edge drag changes **one** dimension — the cut-out crops
    /// rather than scales (measured 191×110 → 128×110 from the left edge) — so
    /// width comes off the left edge and height off the top edge, keeping the
    /// right and bottom edges pinned to the corner we just moved it into.
    private static func placeCutout(in dialog: AXUIElement, widthFraction: CGFloat) -> Bool {
        // Never fight Victor for the cursor: if he's mid-drag, leave it alone.
        guard !CGEventSource.buttonState(.hidSystemState, button: .left) else { return false }
        guard let preview = find(in: dialog, role: kAXUnknownRole,
                                 description: previewAreaLabel),
              let previewRect = frame(of: preview) else { return false }

        // The cut-out only materialises a beat after the layout is selected.
        var cutout: AXUIElement?
        for _ in 0..<12 {
            if let c = firstTabGroup(in: preview) { cutout = c; break }
            usleep(120_000)
        }
        guard let cutout, var rect = frame(of: cutout) else { return false }

        let cursorBefore = CGEvent(source: nil)?.location
        defer {
            if let cursorBefore { CGWarpMouseCursorPosition(cursorBefore) }
        }

        let targetWidth = previewRect.width * widthFraction
        let targetHeight = targetWidth / cutoutAspect
        let tolerance = max(3, previewRect.width * 0.04)

        /// Slide the cut-out so its bottom-right corner meets the preview's.
        func moveToCorner() {
            guard let current = frame(of: cutout) else { return }
            let wantX = previewRect.maxX - current.width
            let wantY = previewRect.maxY - current.height
            guard abs(current.minX - wantX) > 1 || abs(current.minY - wantY) > 1 else { return }
            drag(from: CGPoint(x: current.midX, y: current.midY),
                 to: CGPoint(x: wantX + current.width / 2, y: wantY + current.height / 2))
        }

        for _ in 0..<maxPlacementPasses {
            moveToCorner()
            guard let afterMove = frame(of: cutout) else { return false }
            rect = afterMove

            // Narrow from the left edge — the right edge stays pinned.
            if abs(rect.width - targetWidth) > tolerance {
                drag(from: CGPoint(x: rect.minX + 1.5, y: rect.midY),
                     to: CGPoint(x: previewRect.maxX - targetWidth, y: rect.midY))
                guard let updated = frame(of: cutout) else { return false }
                rect = updated
            }

            // Shorten from the top edge — the bottom edge stays pinned. Without
            // this the frame stays as tall as Zoom made it while only the width
            // shrinks, so the 16:9 video is letterboxed inside a squarish box
            // and a visible gap opens up under Victor's head.
            if abs(rect.height - targetHeight) > tolerance {
                drag(from: CGPoint(x: rect.midX, y: rect.minY + 1.5),
                     to: CGPoint(x: rect.midX, y: previewRect.maxY - targetHeight))
                guard let updated = frame(of: cutout) else { return false }
                rect = updated
            }

            // A resize can nudge the box off the corner; settle it again.
            moveToCorner()
            guard let settled = frame(of: cutout) else { return false }
            rect = settled

            let placed = abs(rect.width - targetWidth) <= tolerance
                && abs(rect.height - targetHeight) <= tolerance
                && abs(rect.maxX - previewRect.maxX) <= tolerance
                && abs(rect.maxY - previewRect.maxY) <= tolerance
            if placed { return true }
        }
        overlayInfo("ZoomSharePrep: cut-out ended at \(rect) inside preview \(previewRect)"
                    + " — wanted \(Int(targetWidth))×\(Int(targetHeight)) flush bottom-right")
        return false
    }

    /// A human-shaped drag: press, move in steps, release. One jump from press to
    /// release is ignored by Zoom's preview, which tracks intermediate motion.
    private static func drag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ at: CGPoint) {
            CGEvent(mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start)
        usleep(30_000)
        post(.leftMouseDown, start)
        usleep(40_000)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t,
                                            y: start.y + (end.y - start.y) * t))
            usleep(12_000)
        }
        usleep(40_000)
        post(.leftMouseUp, end)
        usleep(80_000)
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        guard let posRef = attr(el, kAXPositionAttribute), let sizeRef = attr(el, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The cut-out is the only `AXTabGroup` under the preview area; it is titled
    /// with the participant's display name, which we deliberately don't hardcode.
    private static func firstTabGroup(in root: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 10 { return nil }
        for child in children(root) {
            if string(child, kAXRoleAttribute) == kAXTabGroupRole { return child }
            if let hit = firstTabGroup(in: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    /// The layouts are `AXRadioButton`s that expose **no** `AXPress` and no
    /// selected state — only their nested `AXButton` is pressable. Zoom offers no
    /// way to read which one is active, so we simply press the wanted one; the
    /// press is a no-op when it is already selected. The search is scoped to the
    /// "Choose a layout" list so a same-titled button elsewhere can't be hit.
    private static func selectLayout(_ layout: PresenterLayout, in dialog: AXUIElement) -> Bool {
        guard let list = find(in: dialog, role: kAXListRole, description: layoutListLabel),
              let button = findButton(in: list, title: layout.rawValue) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
}
