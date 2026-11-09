import AppKit
import CoreGraphics

/// 🖥️📡 "Is Victor screen-sharing in a meeting right now?" — Zoom OR Teams,
/// one debounced answer. It gates the 🎙️ voice meter (`VoiceMeter`) and, through
/// it, the ceiling the effects app holds every effect under while the room hears
/// the Mac's sound through the share (victor-effects `VoiceCeiling`).
///
/// - **Zoom**: the share host `CptHost` is running (exactly while a share is up,
///   `OutputRouter` relies on the same fact) OR Zoom shows one of its share
///   windows (`ZoomShareWindows`).
/// - **Teams**: the *sharing control bar* is up (`TeamsShareWindows`).
///
/// Polled every second (one `CGWindowListCopyWindowInfo` + one process scan,
/// a few ms) and debounced: on after 2 s of yes, off after 6 s of no, so a
/// window that blinks while a share is re-targeted does not toggle anything.
/// `force` (`GET /test/sharing/force/on|off|auto`) overrides it for proofs.

/// One window as `CGWindowListCopyWindowInfo` describes it — the probe's input,
/// and what the fixtures in the tests are written in.
struct ShareWindowInfo: Equatable {
    var ownerPID: pid_t
    var name: String?
    /// Global top-left coordinates, points.
    var bounds: CGRect
    var onScreen: Bool
    var layer: Int = 0
}

/// Teams' sharing control bar, recognised in the window list.
///
/// New Teams (`com.microsoft.teams2`, 26289.x) opens a window tagged
/// **`Presenter`** for exactly the length of a share — read off its own logs
/// (`~/Library/Group Containers/UBF8T346G9.com.microsoft.teams/…/Logs/MSTeams_*.log`,
/// `WebViewWindow: Changing to windowNumber=…; tags=Presenter`) for the shares
/// of 26–28 Oct 2026: created at the start, destroyed at the end (07:29:44 →
/// 10:38:29, 11:37:48 → 13:26:08, …), **790 × 55 pt, centred at the top of the
/// shared display** (x = 469 on the 1728-wide Retina = (1728 − 790) / 2,
/// y = 8 or 33), collapsing to **297 × 35** when the pointer leaves it. Teams
/// hides it now and then mid-share (18 s at 08:30:15 on the 26th), so the
/// window list is read with off-screen windows included: the bar stays in it,
/// only `onScreen` flips. The other Teams windows of a call — the meeting
/// window, the 192 × 497 `CallMonitor` compact view — are nothing like it.
///
/// The CG window **title** of that bar was not in the logs, so it is matched by
/// shape and place, plus by a few titles it may plausibly carry ("sharing
/// control bar", "presenter"). The probe logs every Teams window it sees on a
/// share edge, so the first real share pins the title down.
enum TeamsShareWindows {
    static let bundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]

    static func isSharing(windows: [ShareWindowInfo], teamsPIDs: Set<pid_t>, displays: [CGRect]) -> Bool {
        windows.contains { w in
            teamsPIDs.contains(w.ownerPID) && isControlBar(w, displays: displays)
        }
    }

    static func isControlBar(_ w: ShareWindowInfo, displays: [CGRect]) -> Bool {
        if let n = w.name?.lowercased(), n.contains("sharing control bar") || n.contains("sharing toolbar")
            || n.hasPrefix("presenter") { return true }
        let b = w.bounds
        guard (240...900).contains(b.width), (28...110).contains(b.height) else { return false }
        return displays.contains { d in
            b.minY - d.minY >= -2 && b.minY - d.minY <= 45
                && abs(b.midX - d.midX) <= max(8, d.width * 0.02)
        }
    }
}

/// On after `onAfter` consecutive yeses, off after `offAfter` consecutive noes.
struct ShareDebouncer {
    var onAfter: TimeInterval = 2
    var offAfter: TimeInterval = 6
    private(set) var state = false
    private var since: TimeInterval?

    /// A forced state: taken at once, with no pending edge left behind.
    mutating func reset(to value: Bool) { state = value; since = nil }

    /// Feed one raw reading at time `t`; returns the debounced state.
    mutating func feed(_ raw: Bool, at t: TimeInterval) -> Bool {
        if raw == state { since = nil; return state }
        if since == nil { since = t }
        if t - since! >= (raw ? onAfter : offAfter) {
            state = raw
            since = nil
        }
        return state
    }
}

/// The runtime half: polls, debounces, reports edges on main.
final class MeetingShareWatch {
    enum Force: String { case on, off, auto }

    private static let zoomShareHost = "/CptHost.app/Contents/MacOS/CptHost"

    var onChange: ((Bool) -> Void)?
    private(set) var isSharing = false
    private(set) var lastRaw = (zoom: false, teams: false)
    private(set) var force: Force = .auto
    private var debouncer = ShareDebouncer()
    private var timer: Timer?

    func start() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func setForce(_ f: Force) {
        force = f
        overlayInfo("📡 share state forced: \(f.rawValue)")
        tick()
    }

    /// Main thread.
    private func tick() {
        let raw: Bool
        switch force {
        case .on: raw = true
        case .off: raw = false
        case .auto:
            let r = Self.probe()
            if r != lastRaw && (r.zoom || r.teams || lastRaw.zoom || lastRaw.teams) {
                overlayInfo("📡 share probe: zoom=\(r.zoom) teams=\(r.teams)")
                if r.teams != lastRaw.teams { Self.logTeamsWindows() }
            }
            lastRaw = r
            raw = r.zoom || r.teams
        }
        // A forced state lands at once — a test hook that waits 2 s is a flaky test.
        let next: Bool
        if force == .auto {
            next = debouncer.feed(raw, at: CACurrentMediaTime())
        } else {
            debouncer.reset(to: raw)
            next = raw
        }
        guard next != isSharing else { return }
        isSharing = next
        overlayInfo("📡 sharing \(next ? "ON" : "OFF") (\(force == .auto ? "zoom=\(lastRaw.zoom) teams=\(lastRaw.teams)" : "forced"))")
        onChange?(next)
    }

    static func probe() -> (zoom: Bool, teams: Bool) {
        let apps = NSWorkspace.shared.runningApplications
        let zoom = apps.first { $0.bundleIdentifier == ZoomShareWindows.bundleId }
        let teamsPIDs = Set(apps.filter { TeamsShareWindows.bundleIDs.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier))
        guard zoom != nil || !teamsPIDs.isEmpty else { return (false, false) }
        let windows = windowList()
        var zoomSharing = false
        if let zoom {
            zoomSharing = FromWalkieWatchdog.processRunning(executableSuffix: zoomShareHost)
                || ZoomShareWindows.isSharing(windowNames: windows
                    .filter { $0.ownerPID == zoom.processIdentifier && $0.onScreen }.compactMap(\.name))
        }
        let teams = !teamsPIDs.isEmpty && TeamsShareWindows.isSharing(
            windows: windows, teamsPIDs: teamsPIDs, displays: displays())
        return (zoomSharing, teams)
    }

    /// Every window, on-screen or not: Teams hides its bar now and then mid-share.
    static func windowList() -> [ShareWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return nil }
            return ShareWindowInfo(ownerPID: pid, name: w[kCGWindowName as String] as? String, bounds: rect,
                                   onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                                   layer: (w[kCGWindowLayer as String] as? Int) ?? 0)
        }
    }

    /// Global top-left display rectangles, the window list's coordinate space.
    static func displays() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }
    }

    /// One line per Teams window, so the first real share pins its bar's title.
    private static func logTeamsWindows() {
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { TeamsShareWindows.bundleIDs.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        for w in windowList() where pids.contains(w.ownerPID) && w.bounds.width > 1 {
            overlayInfo("📡 teams window '\(w.name ?? "-")' \(Int(w.bounds.minX)),\(Int(w.bounds.minY)) "
                + "\(Int(w.bounds.width))×\(Int(w.bounds.height)) onScreen=\(w.onScreen) layer=\(w.layer)")
        }
    }

    var stateJSON: String {
        "{\"sharing\":\(isSharing),\"force\":\"\(force.rawValue)\",\"rawZoom\":\(lastRaw.zoom),\"rawTeams\":\(lastRaw.teams)}"
    }
}
