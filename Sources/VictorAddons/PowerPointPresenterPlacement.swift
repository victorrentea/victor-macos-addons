import AppKit
import ApplicationServices

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
/// Hold **⌥ while the show starts** to keep PowerPoint's own placement.
final class PowerPointPresenterPlacement {

    private static let bundleID = "com.microsoft.Powerpoint"
    private static let presenterPrefix = "PowerPoint Presenter View"
    private static let slidesPrefix = "PowerPoint Slide Show"
    /// How long after a window appears it is still put back on its screen.
    private static let settleWindow: TimeInterval = 3

    var isEnabled = true

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.ppt-presenter",
                                      qos: .userInitiated)
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var safetyTimer: DispatchSourceTimer?
    /// Title prefix → when that window was first seen, or `.distantPast` when ⌥ said
    /// leave it. Cleared when the window goes away, so the next show starts fresh.
    private var firstSeen: [String: Date] = [:]

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
        guard isEnabled, let app = Self.app() else {
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
        guard !present.isEmpty else { return }

        let screens = Self.screens()
        let targets = [Self.presenterPrefix: PowerPointPresenterPolicy.presenterTarget(screens),
                       Self.slidesPrefix: PowerPointPresenterPolicy.slidesTarget(screens)]
        let now = Date()
        for (prefix, window) in present {
            if firstSeen[prefix] == nil {
                let optionHeld = NSEvent.modifierFlags.contains(.option)
                firstSeen[prefix] = optionHeld ? .distantPast : now
                if optionHeld { overlayInfo("PowerPointPresenterPlacement: ⌥ held — \(prefix) left where PowerPoint put it") }
            }
            guard now.timeIntervalSince(firstSeen[prefix]!) < Self.settleWindow,
                  let target = targets[prefix] ?? nil,
                  let frame = AXWindows.frame(of: window),
                  !PowerPointPresenterPolicy.isOn(target, window: frame) else { continue }
            AXWindows.setFrame(window, target)
            overlayInfo("PowerPointPresenterPlacement: \(prefix) \(frame) → \(target), now \(AXWindows.frame(of: window).map { "\($0)" } ?? "?")")
        }
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
