import AppKit

enum RetinaShareResolutionSettings {
    static let enabledKey = "RetinaShareResolution.enabled"
    /// The Retina's mode before the drop, kept on disk so a crash or a redeploy
    /// mid-share still gives it back: "width,height,pixelWidth,pixelHeight".
    static let restoreKey = "RetinaShareResolution.restoreMode"

    /// On by default: Victor asked for it (2026-11-13).
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var restoreMode: [Int]? {
        get {
            let parts = (UserDefaults.standard.string(forKey: restoreKey) ?? "").split(separator: ",").compactMap { Int($0) }
            return parts.count == 4 ? parts : nil
        }
        set { UserDefaults.standard.set(newValue.map { $0.map(String.init).joined(separator: ",") }, forKey: restoreKey) }
    }
}

/// 🔻 While Zoom or Teams **shares**, the Retina drops to the same size in points
/// at **1×** (1728×1118 px instead of 3456×2234 — 4.4× fewer pixels), and gets its
/// Retina mode back when the share ends (Victor, 2026-11-13: *"change the resolution
/// of the retina to a compatible resolution but lower when sharing with Zoom"*).
///
/// **Why.** Measured that afternoon: Zoom sharing the Retina kept WindowServer at
/// 100–118 % CPU and the cursor lagged on every screen; pausing the share alone took
/// it to ~60 %. WindowServer composites each frame on essentially one thread, so the
/// idle cores don't help — the only lever is fewer pixels per frame. The room sees
/// the share at ≤ 1080p anyway; only the laptop panel itself looks softer meanwhile.
///
/// **Same points, so nothing moves:** the 1× mode is picked by size in points closest
/// to the current one (1728×1117 → 1728×1118), at the current refresh, so windows,
/// the 🪞 cut-out and every saved Retina coordinate stay where they are. Session-only
/// (`CGConfigureDisplayWithDisplayMode … .forSession`). Main thread only.
///
/// Lives beside 🎞️ `RetinaRefreshCap` and doesn't fight it: each matches the mode the
/// other left — this one restores the *size* at whatever refresh is current.
final class RetinaShareResolution {
    /// Zoom or Teams share up (from `MeetingShareWatch`); `/test/retina-share-res?sharing=` pretends.
    var sharing = false {
        didSet { apply() }
    }

    /// Drop or restore, from the setting and `sharing`. Idempotent.
    func apply() {
        guard let id = RetinaRefreshCap.builtInDisplay(), let current = CGDisplayCopyDisplayMode(id) else { return }
        if RetinaShareResolutionSettings.isEnabled && sharing {
            guard current.pixelWidth > current.width else { return }   // already 1×
            guard let low = Self.oneX(of: id, near: current) else {
                overlayInfo("🔻 RetinaShareResolution: no 1× mode near \(current.width)×\(current.height)")
                return
            }
            if RetinaShareResolutionSettings.restoreMode == nil {
                RetinaShareResolutionSettings.restoreMode = [current.width, current.height, current.pixelWidth, current.pixelHeight]
            }
            let err = Self.set(low, on: id)
            overlayInfo("🔻 RetinaShareResolution: sharing → Retina \(current.pixelWidth)×\(current.pixelHeight) → \(low.pixelWidth)×\(low.pixelHeight) (err \(err))")
        } else {
            restore()
        }
    }

    /// The Retina mode from before the drop, if there is one to give back.
    func restore() {
        guard let saved = RetinaShareResolutionSettings.restoreMode else { return }
        RetinaShareResolutionSettings.restoreMode = nil
        guard let id = RetinaRefreshCap.builtInDisplay(), let current = CGDisplayCopyDisplayMode(id),
              current.pixelWidth != saved[2] || current.pixelHeight != saved[3],
              let back = Self.mode(of: id, saved: saved, hz: current.refreshRate) else { return }
        let err = Self.set(back, on: id)
        overlayInfo("🔻 RetinaShareResolution: share over → Retina back to \(back.pixelWidth)×\(back.pixelHeight) (err \(err))")
    }

    func snapshotJSON() -> String {
        let m = RetinaRefreshCap.builtInDisplay().flatMap(CGDisplayCopyDisplayMode)
        let o: [String: Any] = ["enabled": RetinaShareResolutionSettings.isEnabled, "sharing": sharing,
                                "retina": m.map { "\($0.width)x\($0.height) px=\($0.pixelWidth)x\($0.pixelHeight) @\(Int($0.refreshRate))" } ?? "",
                                "restoreMode": RetinaShareResolutionSettings.restoreMode ?? []]
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Display modes

    private static func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    /// The usable 1× mode whose size in points is closest to `current`'s, at its refresh.
    static func oneX(of id: CGDirectDisplayID, near current: CGDisplayMode) -> CGDisplayMode? {
        allModes(id)
            .filter { $0.pixelWidth == $0.width && $0.isUsableForDesktopGUI()
                && abs($0.refreshRate - current.refreshRate) < 0.5 }
            .min { abs($0.width - current.width) + abs($0.height - current.height)
                < abs($1.width - current.width) + abs($1.height - current.height) }
    }

    /// The mode with the saved size (points and pixels), at `hz` if it exists, else any refresh.
    static func mode(of id: CGDirectDisplayID, saved: [Int], hz: Double) -> CGDisplayMode? {
        let same = allModes(id).filter {
            $0.width == saved[0] && $0.height == saved[1] && $0.pixelWidth == saved[2] && $0.pixelHeight == saved[3]
        }
        return same.first { abs($0.refreshRate - hz) < 0.5 } ?? same.max { $0.refreshRate < $1.refreshRate }
    }

    private static func set(_ mode: CGDisplayMode, on id: CGDirectDisplayID) -> Int32 {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return -1 }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession).rawValue
    }
}
