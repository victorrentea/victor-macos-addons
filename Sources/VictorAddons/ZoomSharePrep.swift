import AppKit
import ApplicationServices

/// 🔊 Prepares Zoom's screen-share picker the instant it opens: ticks **Share
/// sound** and selects the **presenter layout**, so Victor never again shares a
/// demo the room can't hear.
///
/// **Why this exists.** Zoom resets both of these at the start of every meeting.
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
    private static let zoomBundleID = "us.zoom.xos"

    /// Zoom's four presenter layouts, exactly as their buttons are titled.
    /// `overTheShoulder` is the one that composites Victor's camera **over** the
    /// shared content on the right — what the participants actually see.
    enum PresenterLayout: String, CaseIterable {
        case contentOnly = "Content only"
        case asBackground = "As background"
        case overTheShoulder = "Over the shoulder"
        case sideBySide = "Side by side"
    }

    /// Set to nil to leave the layout alone and only handle the sound checkbox.
    var presenterLayout: PresenterLayout? = .overTheShoulder
    var isEnabled = true

    /// Shows the 🔊✅ / 🔊❌ confirmation. Injected so tests can run headless.
    var onResult: ((Result) -> Void)?

    struct Result {
        let soundWasAlreadyOn: Bool
        let soundOnNow: Bool
        let layoutApplied: PresenterLayout?
    }

    // MARK: - Lifecycle

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.zoom-share-prep",
                                      qos: .userInitiated)
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var safetyTimer: DispatchSourceTimer?
    /// Rising-edge guard: we act once per appearance of the picker, not per scan.
    private var dialogWasOpen = false

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
            return
        }
        guard !dialogWasOpen else { return }   // already handled this appearance

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

        let result = Result(soundWasAlreadyOn: wasOn, soundOnNow: onNow, layoutApplied: appliedLayout)
        overlayInfo("ZoomSharePrep: share sound \(wasOn ? "already on" : (onNow ? "ticked" : "FAILED to tick"))"
                    + (appliedLayout.map { ", layout → \($0.rawValue)" } ?? ""))
        DispatchQueue.main.async { [weak self] in self?.onResult?(result) }
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
