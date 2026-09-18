import AppKit
import ApplicationServices

/// ▶️ Presses **Join** / **Start** in Zoom's join-preview dialog the instant it
/// appears, so joining a meeting is one click (the link) instead of two.
///
/// **The dialog.** Zoom 6.x shows a 640×511 preview window titled with the
/// *meeting topic* — "agentic.how #4" — holding a camera preview, audio/video
/// toggles, device pickers and a blue confirm button. It is gated by
/// **Settings → Meetings & webinars → Join experience → "Show video preview
/// first"**; with that switch off, Zoom joins straight away and this watcher
/// never fires. The in-dialog checkbox is the same setting under another name.
///
/// **Matching, and why not by title.** The window's title is the meeting topic,
/// so there is nothing constant to match on — unlike `ZoomSharePrep`, whose
/// picker is always "Share screen window". The handle used instead is the
/// checkbox, whose label is fixed for every meeting, and the button is found
/// under that same window. Dumped from Zoom 6.6:
///
/// ```
/// AXWindow Subrole=AXStandardWindow Title="agentic.how #4"
///   AXTabGroup
///     AXButton Desc="Video, turn off, currently on"   Id=Video
///     AXButton Desc="Audio, turn off, currently unmuted" Id=Audio
///   AXButton Desc="Join"                                    actions=[AXPress]
///   AXCheckBox Desc="Always show this preview when joining" Value=1
///   AXButton Desc="Turn off to skip this preview in future meetings. …"
/// ```
///
/// Two traps that shaped the matching. The confirm button carries its label in
/// **`AXDescription`, not `AXTitle`** (an `AXTitle` search finds nothing), and
/// its text depends on the role: **"Join"** when joining someone's meeting,
/// **"Start"** when starting your own. Both are accepted. The match is exact
/// rather than a prefix, because the ⓘ button beside the checkbox has a
/// *description* that contains the word "preview" and would swallow a loose
/// search.
///
/// Driven in-process through `AXUIElement` on this app's own Accessibility
/// grant, for the reasons written out at length in `ZoomSharePrep` — the same
/// window-created observer plus a safety poll, because Zoom sometimes reuses the
/// window instead of creating one and the notification never arrives then.
///
/// **Escape hatch**: hold **⌥ while the dialog appears** to keep it open and
/// pick a camera, a microphone or a background by hand. Same gesture and same
/// reasoning as `ZoomSharePrep.autoPressShare`.
final class ZoomJoinAutoStart {

    /// The checkbox that identifies the preview dialog — constant across
    /// meetings, unlike the window's title.
    private static let previewCheckboxLabel = "Always show this preview when joining"
    /// The confirm button's `AXDescription`: "Join" someone else's meeting,
    /// "Start" your own.
    private static let confirmLabels = ["Join", "Start"]
    private static let zoomBundleID = "us.zoom.xos"

    var isEnabled = true

    /// Reports every press so the app can log it; injected so tests run headless.
    var onJoined: ((String) -> Void)?

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.zoom-join-autostart",
                                      qos: .userInitiated)
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var safetyTimer: DispatchSourceTimer?
    /// Rising-edge guard: one press per appearance of the dialog, so a press
    /// that Zoom ignores while the window is still animating isn't hammered.
    private var dialogWasOpen = false

    // MARK: - Lifecycle

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
            let me = Unmanaged<ZoomJoinAutoStart>.fromOpaque(refcon).takeUnretainedValue()
            me.scanSoon()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }

        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(obs, appEl, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
        overlayInfo("ZoomJoinAutoStart: watching Zoom (pid \(pid))")
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

    /// The dialog's subtree fills in asynchronously, so a scan fired the instant
    /// the window is created usually finds an empty shell. Same retry ladder as
    /// the share picker.
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
        // Zoom can block on its own main thread while it connects; never let an
        // AX call wedge our queue behind it.
        AXUIElementSetMessagingTimeout(appEl, 1.0)

        guard let dialog = Self.previewDialog(in: appEl) else {
            dialogWasOpen = false
            return
        }
        guard !dialogWasOpen else { return }

        guard let button = Self.confirmButton(in: dialog) else {
            return  // subtree not populated yet — a later retry will find it
        }
        dialogWasOpen = true

        // ⌥ held = "let me set my camera and mic up first".
        if KeySimulator.heldModifiers().contains(.maskAlternate) {
            overlayInfo("ZoomJoinAutoStart: ⌥ held → left the preview open")
            return
        }

        let label = Self.string(button, kAXDescriptionAttribute) ?? "?"
        let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        let topic = Self.string(dialog, kAXTitleAttribute) ?? "?"
        overlayInfo("ZoomJoinAutoStart: \(pressed ? "pressed" : "FAILED to press") \(label) for \"\(topic)\"")
        if pressed {
            DispatchQueue.main.async { [weak self] in self?.onJoined?(topic) }
        }
    }

    /// `GET /test/zoom-join` — reports what the scanner can see right now and
    /// re-arms it, so a preview left open can be pressed without re-joining.
    /// See docs/testing.md.
    func testSnapshotJSON() -> String {
        guard let app = Self.zoomApp() else { return #"{"zoomRunning":false}"# }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        let dialog = Self.previewDialog(in: appEl)
        let button = dialog.flatMap { Self.confirmButton(in: $0) }
        let snapshot = """
        {"zoomRunning":true,"enabled":\(isEnabled),"previewOpen":\(dialog != nil),\
        "topic":\(dialog.flatMap { Self.string($0, kAXTitleAttribute) }.map { "\"\($0)\"" } ?? "null"),\
        "confirmButton":\(button.flatMap { Self.string($0, kAXDescriptionAttribute) }.map { "\"\($0)\"" } ?? "null")}
        """
        queue.async { [weak self] in
            self?.dialogWasOpen = false
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

    /// The preview window is the one carrying the "always show this preview"
    /// checkbox — the only part of it that reads the same for every meeting.
    private static func previewDialog(in appEl: AXUIElement) -> AXUIElement? {
        let windows = attr(appEl, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { hasPreviewCheckbox($0) }
    }

    private static func hasPreviewCheckbox(_ root: AXUIElement, depth: Int = 0) -> Bool {
        if depth > 8 { return false }
        for child in children(root) {
            if string(child, kAXRoleAttribute) == kAXCheckBoxRole,
               string(child, kAXDescriptionAttribute) == previewCheckboxLabel {
                return true
            }
            if hasPreviewCheckbox(child, depth: depth + 1) { return true }
        }
        return false
    }

    /// The blue confirm button, matched on its **description** — exactly, so the
    /// ⓘ button's long description can't be mistaken for it — and only while
    /// Zoom has it enabled.
    private static func confirmButton(in dialog: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 8 { return nil }
        for child in children(dialog) {
            if string(child, kAXRoleAttribute) == kAXButtonRole,
               let desc = string(child, kAXDescriptionAttribute),
               confirmLabels.contains(desc),
               (attr(child, kAXEnabledAttribute) as? Bool) != false {
                return child
            }
            if let hit = confirmButton(in: child, depth: depth + 1) { return hit }
        }
        return nil
    }
}
