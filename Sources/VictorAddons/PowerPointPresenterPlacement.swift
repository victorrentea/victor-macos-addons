import AppKit
import ApplicationServices

/// The 🖥️ PowerPoint Presenter View row in 👩🏻‍💻 Extra. Default **on**: the
/// placement shipped running before the row existed. Read on every scan, like
/// `ZoomSharePrepSettings`, so the tick and the behaviour cannot drift apart.
enum PowerPointPresenterSettings {
    static let enabledKey = "PowerPointPresenterPlacement.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// 🖥️ Puts PowerPoint's **Presenter View on the leftmost external screen** and the
/// **slides on the Retina** the moment a slide show starts — the choice PowerPoint
/// for Mac leaves to Quartz display ids (see `PowerPointPresenterPolicy`).
///
/// **Why Accessibility, not AppleScript.** PowerPoint's dictionary does expose a
/// writable `slide show window` frame, but while Presenter View is up PowerPoint
/// stops answering Apple Events altogether — every query hung past its timeout
/// (measured 2026-10-23), and a show started from AppleScript skips Presenter View
/// and mirrors instead. Both windows are plain layer-0 windows to AX, positions
/// settable, so they are moved in-process on this app's own grant — the same
/// window-created observer plus safety poll as `ZoomJoinAutoStart`.
///
/// **Only at the start.** Each window is placed during its first few seconds
/// (PowerPoint may still nudge it while it lays the show out), then left alone, so
/// a window Victor drags elsewhere — or PowerPoint's own *Swap Displays* — sticks.
/// Turned off by unticking the 🖥️ row in 👩🏻‍💻 Extra (`PowerPointPresenterSettings`);
/// there is no key for it — the ⌥-at-start escape went on 2026-10-23.
final class PowerPointPresenterPlacement {

    private static let bundleID = "com.microsoft.Powerpoint"
    private static let presenterPrefix = "PowerPoint Presenter View"
    private static let slidesPrefix = "PowerPoint Slide Show"
    /// How long after a window appears it is still put back on its screen.
    private static let settleWindow: TimeInterval = 3

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.ppt-presenter",
                                      qos: .userInitiated)
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var safetyTimer: DispatchSourceTimer?
    /// Title prefix → when that window was first seen. Cleared when the window goes
    /// away, so the next show starts fresh.
    private var firstSeen: [String: Date] = [:]
    /// Displays mirroring the Retina at the last scan without a show, and when
    /// that was last true. PowerPoint breaks the mirror ~0.5 s before its windows
    /// appear, so a scan landing in that gap must not forget the set at once.
    private var mirroredBefore: Set<UInt32> = []
    private var mirroredSeenAt = Date.distantPast
    /// Once per show: a mirror Victor breaks by hand mid-show stays broken.
    private var remirrored = false
    private static let mirrorMemory: TimeInterval = 5

    // MARK: - Lifecycle

    func start() {
        attachIfRunning()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.bundleID else { return }
            self?.attachIfRunning()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.bundleID else { return }
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

    private static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private func attachIfRunning() {
        guard let app = Self.app() else { return }
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        detach()

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<PowerPointPresenterPlacement>.fromOpaque(refcon).takeUnretainedValue().scanSoon()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, AXUIElementCreateApplication(pid),
                                  kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
        overlayInfo("PowerPointPresenterPlacement: watching PowerPoint (pid \(pid))")
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        queue.async { [weak self] in self?.firstSeen = [:] }
    }

    // MARK: - Scanning

    /// The window is created before PowerPoint has sized it to its screen; look
    /// again a few times so the move lands after PowerPoint's own placement.
    private func scanSoon() {
        for delay in [0.1, 0.4, 1.0, 2.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
        }
    }

    private func scan() {
        guard PowerPointPresenterSettings.isEnabled, let app = Self.app() else {
            firstSeen = [:]
            return
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // Presenter View keeps PowerPoint's main thread busy; never wedge our queue.
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        var raw: CFTypeRef?
        let windows = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &raw) == .success
            ? (raw as? [AXUIElement]) ?? [] : []

        var present: [String: AXUIElement] = [:]
        for w in windows {
            guard let title = AXWindows.title(of: w) else { continue }
            for prefix in [Self.presenterPrefix, Self.slidesPrefix] where title.hasPrefix(prefix) {
                present[prefix] = w
            }
        }
        firstSeen = firstSeen.filter { present[$0.key] != nil }
        guard !present.isEmpty else {
            rememberMirror()
            return
        }

        // While the show runs, the displays PowerPoint pulled out of the mirror are
        // not screens for Presenter View: they go back to mirroring the Retina.
        let stillRemembered = Date().timeIntervalSince(mirroredSeenAt) < Self.mirrorMemory || remirrored
        let roomScreens = stillRemembered ? mirroredBefore : []
        let screens = Self.screens().filter { !roomScreens.contains($0.id) }
        let targets = [Self.presenterPrefix: PowerPointPresenterPolicy.presenterTarget(screens),
                       Self.slidesPrefix: PowerPointPresenterPolicy.slidesTarget(screens)]
        let now = Date()
        for (prefix, window) in present {
            if firstSeen[prefix] == nil { firstSeen[prefix] = now }
            guard now.timeIntervalSince(firstSeen[prefix]!) < Self.settleWindow,
                  let target = targets[prefix] ?? nil,
                  let frame = AXWindows.frame(of: window),
                  !PowerPointPresenterPolicy.isOn(target, window: frame) else { continue }
            AXWindows.setFrame(window, target)
            overlayInfo("PowerPointPresenterPlacement: \(prefix) \(frame) → \(target), now \(AXWindows.frame(of: window).map { "\($0)" } ?? "?")")
        }

        // Only once Presenter View exists and has been moved off the room screen.
        if !remirrored, present[Self.presenterPrefix] != nil {
            remirrored = true
            remirror(roomScreens)
            // The reconfiguration may shove the windows again: keep placing them.
            for key in firstSeen.keys { firstSeen[key] = Date() }
        }
    }

    private func rememberMirror() {
        remirrored = false
        let now = Self.mirroringRetina()
        if !now.isEmpty {
            mirroredBefore = now
            mirroredSeenAt = Date()
        } else if Date().timeIntervalSince(mirroredSeenAt) >= Self.mirrorMemory {
            mirroredBefore = []
        }
    }

    private func remirror(_ wanted: Set<UInt32>) {
        guard let retina = Self.builtinID() else { return }
        let ids = PowerPointPresenterPolicy.toRemirror(mirroredBefore: wanted,
                                                       online: Self.onlineIDs(),
                                                       mirroringRetina: Self.mirroringRetina())
        guard !ids.isEmpty else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for id in ids { CGConfigureDisplayMirrorOfDisplay(config, id, retina) }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        overlayInfo("PowerPointPresenterPlacement: PowerPoint broke the mirror → re-mirroring \(ids.sorted()) onto the Retina (\(err == .success ? "ok" : "error \(err.rawValue)"))")
    }

    private static func onlineIDs() -> Set<UInt32> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Set(physicalDisplayIDs(ids.prefix(Int(count))))
    }

    private static func builtinID() -> UInt32? {
        onlineIDs().first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func mirroringRetina() -> Set<UInt32> {
        guard let retina = builtinID() else { return [] }
        return onlineIDs().filter { CGDisplayMirrorsDisplay($0) == retina }
    }

    /// Active displays a window can sit on: no mirror slaves, no 🪞 virtual desktop.
    private static func screens() -> [PresenterScreen] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return physicalDisplayIDs(ids.prefix(Int(count)))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { PresenterScreen(id: $0, frame: CGDisplayBounds($0), isBuiltin: CGDisplayIsBuiltin($0) != 0) }
    }
}
