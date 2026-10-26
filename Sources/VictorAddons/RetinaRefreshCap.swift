import AppKit

enum RetinaRefreshCapSettings {
    static let enabledKey = "RetinaRefreshCap.enabled"
    /// The Retina's refresh before the cap, kept on disk so a crash or a redeploy
    /// mid-meeting still gives it back.
    static let restoreKey = "RetinaRefreshCap.restoreHz"

    /// On by default: Victor asked for it (2026-10-26).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var restoreHz: Double? {
        get { UserDefaults.standard.object(forKey: restoreKey) as? Double }
        set { UserDefaults.standard.set(newValue, forKey: restoreKey) }
    }
}

/// While Zoom or Teams runs, the Retina refreshes at **60 Hz at most** (Victor,
/// 2026-10-26: *"când activez screen share să coboare la 60 Hz refresh rate maxim
/// retina… cu bifa"*, and the trigger he picked: *"cât rulează Zoom sau Teams"*).
/// The share and the projector never get more than 60 anyway — Zoom sends ≤ 30 fps —
/// so 120 Hz ProMotion only costs WindowServer during a call. Measured the same
/// evening with ShareZoom panning on the Retina: WindowServer 60–62 % at 120 Hz,
/// 63 % at 60 Hz, inside the noise; the cap is Victor's choice, not a measured win.
///
/// The mode is the same size at 60 Hz (`CGConfigureDisplayWithDisplayMode`, for the
/// session only), and the refresh it had is put back when the last meeting app quits,
/// the tick comes off, or this app quits. Main thread only.
///
/// Born in Victor Mirror the same day and moved here hours later (Victor: *"move to
/// macos addons"*): Mirror is kept for the 🪞 screen alone, so that it is redeployed
/// as rarely as possible.
final class RetinaRefreshCap {
    static let capHz = 60.0

    static let meetingApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2"]

    /// Whether Zoom or Teams runs; `/test/retina-cap?meeting=` pretends until the next launch/quit.
    var meeting = false {
        didSet { apply() }
    }

    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.apply() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier.map(Self.meetingApps.contains) == true else { return }
                self?.meeting = Self.meetingAppRunning()
            }
        }
        meeting = Self.meetingAppRunning()
    }

    static func meetingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier.map(meetingApps.contains) == true && !$0.isTerminated
        }
    }

    /// Cap or uncap, from the setting and `meeting`. Idempotent: a display change
    /// (our own included) only re-checks.
    func apply() {
        guard let id = Self.builtInDisplay(), let current = CGDisplayCopyDisplayMode(id) else { return }
        if RetinaRefreshCapSettings.isEnabled && meeting {
            guard current.refreshRate > Self.capHz + 0.5 else { return }
            guard let capped = Self.mode(of: id, like: current, hz: Self.capHz) else {
                overlayInfo("🎞️ RetinaRefreshCap: no \(Int(Self.capHz)) Hz mode at \(current.width)×\(current.height)")
                return
            }
            if RetinaRefreshCapSettings.restoreHz == nil { RetinaRefreshCapSettings.restoreHz = current.refreshRate }
            let err = Self.set(capped, on: id)
            overlayInfo("🎞️ RetinaRefreshCap: Zoom/Teams running → Retina \(Int(current.refreshRate)) → \(Int(Self.capHz)) Hz (err \(err))")
        } else {
            restore()
        }
    }

    /// The refresh from before the cap, if there is one to give back.
    func restore() {
        guard let hz = RetinaRefreshCapSettings.restoreHz else { return }
        RetinaRefreshCapSettings.restoreHz = nil
        guard let id = Self.builtInDisplay(), let current = CGDisplayCopyDisplayMode(id),
              abs(current.refreshRate - hz) > 0.5,
              let back = Self.mode(of: id, like: current, hz: hz) else { return }
        let err = Self.set(back, on: id)
        overlayInfo("🎞️ RetinaRefreshCap: Retina back to \(Int(hz)) Hz (err \(err))")
    }

    func snapshotJSON() -> String {
        let hz = Self.builtInDisplay().flatMap(CGDisplayCopyDisplayMode)?.refreshRate ?? 0
        let o: [String: Any] = ["enabled": RetinaRefreshCapSettings.isEnabled, "meeting": meeting,
                                "retinaHz": hz, "restoreHz": RetinaRefreshCapSettings.restoreHz ?? 0]
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Display modes

    static func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// The mode with `current`'s size (points and pixels) at `hz`.
    static func mode(of id: CGDirectDisplayID, like current: CGDisplayMode, hz: Double) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        return modes.first {
            $0.width == current.width && $0.height == current.height
                && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
                && abs($0.refreshRate - hz) < 0.01
        }
    }

    private static func set(_ mode: CGDisplayMode, on id: CGDirectDisplayID) -> Int32 {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return -1 }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession).rawValue
    }
}
