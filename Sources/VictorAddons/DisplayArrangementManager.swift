import Cocoa
import CoreGraphics

/// Auto-arranges displays for the projector workflow.
///
/// **The rule** (Victor's fixed setup at every venue):
///
/// - **Projector connected** → the projector *mirrors* the built-in Retina, and
///   the Retina drops to **1920×1080** (a projector-friendly 1080p signal — this
///   is "what's projected to the room"). If the **ASUS MB166C** portable monitor
///   is also connected it becomes the **primary/main** display (menu bar), sitting
///   to the **right**, with the Retina extended to **its left**.
/// - **No projector** → the standard rig: **Retina is main** at its native
///   resolution, with the ASUS (if present) extended to the Retina's **right**.
///
/// Detection is via `CGDisplayRegisterReconfigurationCallback` (fires on every
/// hot-plug / mode / mirror change), debounced ~1.2 s so the hardware settles
/// before we read + apply. We only act when the *scene* — `(hasProjector,
/// hasASUS)` — actually changes, so re-applying our own layout doesn't loop.
///
/// Applying uses Quartz Display Services (`CGBegin/CompleteDisplayConfiguration`)
/// — a single atomic transaction, no external tools, no extra entitlements
/// (reconfiguring displays needs no Screen-Recording permission).
///
/// Roles are identified live, not from a frozen profile, so this works with *any*
/// venue's projector (different EDID every time): built-in = Retina
/// (`CGDisplayIsBuiltin`); name contains "ASUS" = the portable; anything else
/// external = the projector.
final class DisplayArrangementManager {
    /// Fired on the main queue after an arrangement is applied, with a short
    /// human banner string (e.g. "🖥️ Projector: mirrored + ASUS primary").
    var onArrangementApplied: ((String) -> Void)?

    /// Fired (deduped) whenever the "an unknown external display is connected"
    /// signal flips — i.e. a venue projector / room TV appeared or went away.
    /// Drives `PresentationDetector`. Called on the main queue.
    var onUnknownExternalChanged: ((Bool) -> Void)?

    private let knownDisplays: KnownDisplays

    init(knownDisplays: KnownDisplays) {
        self.knownDisplays = knownDisplays
    }

    /// A resolved set of the displays we care about at one instant.
    private struct DisplaySet {
        var retina: CGDirectDisplayID?
        var asus: CGDirectDisplayID?
        /// First unknown external (venue projector / room TV), if any.
        var projector: CGDirectDisplayID?
        /// Known non-ASUS externals (home monitors / TV). Their presence means
        /// we're at home / a familiar rig, so auto-arrange keeps its hands off —
        /// except we never allow one to stay *mirroring* the Retina (see below).
        var knownExternals: [CGDirectDisplayID] = []
        var hasKnownExternal: Bool { !knownExternals.isEmpty }
    }

    /// The decision key: re-apply only when this changes.
    private struct Scene: Equatable {
        let projector: Bool
        let asus: Bool
    }

    private var reconfigureRegistered = false
    private var debounce: DispatchWorkItem?
    private var isApplying = false
    private var lastScene: Scene?
    /// Deduplicates the unknown-external (presentation) signal.
    private var lastUnknownExternal: Bool?

    /// The Retina's user-normal (native HiDPI) mode, captured the first time we
    /// observe a projector-free state. Restored verbatim when reverting, so we
    /// never guess the scaled resolution the user actually runs.
    private var standardRetinaMode: CGDisplayMode?

    // MARK: - Lifecycle

    /// Register the reconfiguration callback and snapshot the current state as
    /// the baseline. We deliberately do **not** auto-apply on launch — only on
    /// subsequent *changes* — so starting the app never reshuffles a layout the
    /// user is happily using. Use `applyNow()` (menu / test hook) to force it.
    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let err = CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard let ctx else { return }
            Unmanaged<DisplayArrangementManager>.fromOpaque(ctx)
                .takeUnretainedValue()
                .reconfigured(flags)
        }, ctx)
        reconfigureRegistered = (err == .success)

        let displays = resolveDisplays()
        captureStandardRetinaModeIfNeeded(displays)
        lastScene = scene(for: displays)
        overlayInfo("DisplayArrangementManager started (registered=\(reconfigureRegistered)); "
            + "baseline scene=\(describe(lastScene)); \(describe(displays))")
        // Propagate the initial presentation signal (e.g. launched at a venue
        // with the projector already plugged in).
        notifyUnknownExternal(displays.projector != nil)
    }

    // MARK: - Detection

    private func reconfigured(_ flags: CGDisplayChangeSummaryFlags) {
        // Ignore the pre-change "begin" pulse and anything we ourselves trigger.
        if flags.contains(.beginConfigurationFlag) { return }
        if isApplying { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluateAndApply(force: false) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Re-read the displays and apply the arrangement. `force` bypasses the
    /// "scene unchanged" guard (used by the menu item + `/test/projector`), so a
    /// venue projector that came up in a weird state can be re-fixed on demand.
    private func evaluateAndApply(force: Bool) {
        let displays = resolveDisplays()
        captureStandardRetinaModeIfNeeded(displays)
        // Always refresh the presentation signal first — even when the arrange
        // scene is unchanged or suppressed below.
        notifyUnknownExternal(displays.projector != nil)

        let target = scene(for: displays)
        if !force, target == lastScene {
            overlayInfo("Display change ignored (scene unchanged: \(describe(target)))")
            return
        }
        lastScene = target

        // A familiar multi-display rig: when KNOWN non-ASUS externals (home
        // monitors / TV) are present, Victor's own layout — the exact positions
        // and resolutions he set — is kept **verbatim**. The ONE invariant we
        // enforce is that no home display *mirrors* the Retina; we touch only a
        // display actually caught in a mirror set (see `unmirrorHomeDisplays`),
        // never the ones already extended. A venue (unknown projector) never has
        // these connected. Even the manual "🖥️ Fix display layout" (force) only
        // breaks stray mirroring here — it does not re-shuffle the home layout.
        if displays.hasKnownExternal {
            unmirrorHomeDisplays(displays)
            return
        }

        apply(scene: target, displays: displays)
    }

    /// Notify the presentation layer (deduped) that the unknown-external signal
    /// flipped. `notifyUnknownExternal(present)` runs on the main queue already
    /// (start / debounced evaluate / refresh all do).
    private func notifyUnknownExternal(_ present: Bool) {
        guard present != lastUnknownExternal else { return }
        lastUnknownExternal = present
        onUnknownExternalChanged?(present)
    }

    // MARK: - Public triggers

    /// Force-apply the correct arrangement for whatever is connected right now.
    /// Backs the "🖥️ Fix display layout" menu item.
    func applyNow() {
        DispatchQueue.main.async { [weak self] in self?.evaluateAndApply(force: true) }
    }

    /// Force-apply now, then return a JSON snapshot of the resulting state.
    /// Backs `/test/projector`. Must be called on the main queue (the HTTP
    /// handler wraps it in `DispatchQueue.main.sync`).
    func forceApplyAndSnapshot() -> String {
        evaluateAndApply(force: true)
        return snapshotJSON()
    }

    /// JSON snapshot of what we detect + the resolved scene, for the test hook.
    func snapshotJSON() -> String {
        let d = resolveDisplays()
        let s = scene(for: d)
        func nm(_ id: CGDirectDisplayID?) -> String {
            guard let id else { return "null" }
            return "\"\(screenName(for: id) ?? "display \(id)")\""
        }
        let retinaModeStr: String
        if let r = d.retina, let m = CGDisplayCopyDisplayMode(r) {
            retinaModeStr = "\"\(m.width)x\(m.height) (px \(m.pixelWidth)x\(m.pixelHeight))\""
        } else {
            retinaModeStr = "null"
        }
        let has1080 = d.retina.flatMap { find1080Mode($0) } != nil
        return "{"
            + "\"retina\":\(nm(d.retina)),"
            + "\"asus\":\(nm(d.asus)),"
            + "\"projector\":\(nm(d.projector)),"
            + "\"scene\":\"\(s.projector ? "projector" : "standard")\","
            + "\"retinaMode\":\(retinaModeStr),"
            + "\"retina1080Available\":\(has1080),"
            + "\"registered\":\(reconfigureRegistered)"
            + "}"
    }

    // MARK: - Role resolution

    private func resolveDisplays() -> DisplaySet {
        var set = DisplaySet()
        for id in onlineDisplayIDs() {
            switch role(of: id) {
            case .retina:        if set.retina == nil { set.retina = id }
            case .asus:          if set.asus == nil { set.asus = id }
            case .knownExternal: set.knownExternals.append(id)
            case .projector:     if set.projector == nil { set.projector = id }
            }
        }
        return set
    }

    private enum Role { case retina, asus, knownExternal, projector }

    private func role(of id: CGDirectDisplayID) -> Role {
        if CGDisplayIsBuiltin(id) != 0 { return .retina }
        // The ASUS travel monitor gets its own arrangement role (primary/right).
        if let name = screenName(for: id), name.uppercased().contains("ASUS") {
            return .asus
        }
        // Any other display Victor has marked as his own (home monitors / TV):
        // a normal extended desktop — never mirrored, never "presenting".
        if knownDisplays.isKnown(id) { return .knownExternal }
        // Anything else external = a venue projector / room TV = unknown.
        return .projector
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private func screenName(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == id {
                return screen.localizedName
            }
        }
        return nil
    }

    private func scene(for displays: DisplaySet) -> Scene {
        Scene(projector: displays.projector != nil, asus: displays.asus != nil)
    }

    private func captureStandardRetinaModeIfNeeded(_ displays: DisplaySet) {
        guard standardRetinaMode == nil,
              displays.projector == nil,          // only trust the mode when no projector
              let retina = displays.retina,
              let mode = CGDisplayCopyDisplayMode(retina),
              mode.pixelWidth > mode.width else { return }  // HiDPI only — never snapshot a mirror-forced 1080p as "standard"
        standardRetinaMode = mode
        overlayInfo("Captured standard Retina mode: \(mode.width)x\(mode.height) "
            + "(px \(mode.pixelWidth)x\(mode.pixelHeight))")
    }

    // MARK: - Applying

    private func apply(scene: Scene, displays: DisplaySet) {
        isApplying = true
        defer {
            // Keep swallowing our own reconfiguration callbacks briefly after the
            // transaction settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isApplying = false
            }
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            overlayError("CGBeginDisplayConfiguration failed — arrangement not applied")
            return
        }

        let banner: String
        if scene.projector, let projector = displays.projector, let retina = displays.retina {
            banner = applyProjector(config: config, retina: retina, projector: projector, asus: displays.asus)
        } else if let retina = displays.retina {
            banner = applyStandard(config: config, retina: retina, asus: displays.asus)
        } else {
            _ = CGCancelDisplayConfiguration(config)
            return
        }

        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result == .success {
            overlayInfo("Display arrangement applied: \(banner)")
            DispatchQueue.main.async { [weak self] in self?.onArrangementApplied?(banner) }
        } else {
            overlayError("CGCompleteDisplayConfiguration failed (\(result.rawValue)) — \(banner)")
        }
    }

    /// Projector present: Retina→1080p mirrored by the projector; ASUS (if any)
    /// primary on the right, Retina extended to its left.
    private func applyProjector(config: CGDisplayConfigRef,
                                retina: CGDirectDisplayID,
                                projector: CGDirectDisplayID,
                                asus: CGDirectDisplayID?) -> String {
        var retinaPointWidth: Int32 = 1920
        if let mode = find1080Mode(retina) {
            CGConfigureDisplayWithDisplayMode(config, retina, mode, nil)
            retinaPointWidth = Int32(mode.width)
        } else {
            overlayError("No 1920×1080 mode on the Retina — mirroring at current mode")
            if let cur = CGDisplayCopyDisplayMode(retina) { retinaPointWidth = Int32(cur.width) }
        }

        // Projector mirrors the Retina (shares its bounds — do not place it).
        CGConfigureDisplayMirrorOfDisplay(config, projector, retina)

        if let asus = asus {
            CGConfigureDisplayMirrorOfDisplay(config, asus, kCGNullDirectDisplay)
            // Un-mirroring drops a former mirror slave to a fallback mode (e.g.
            // 800×600); if macOS swept the ASUS into the mirror set when the
            // projector appeared, breaking that mirror leaves it there. Pin it
            // back to its native mode so it isn't primary at 800×600.
            if let m = bestMode(asus) { CGConfigureDisplayWithDisplayMode(config, asus, m, nil) }
            CGConfigureDisplayOrigin(config, asus, 0, 0)                 // (0,0) ⇒ main
            CGConfigureDisplayOrigin(config, retina, -retinaPointWidth, 0) // to ASUS's left
            return "🖥️ Projector: mirror + ASUS primary (Retina 1080p left)"
        } else {
            CGConfigureDisplayOrigin(config, retina, 0, 0)
            return "🖥️ Projector: mirrored (Retina 1080p)"
        }
    }

    /// No projector: Retina main at its native mode; ASUS (if any) to the right.
    private func applyStandard(config: CGDisplayConfigRef,
                               retina: CGDirectDisplayID,
                               asus: CGDirectDisplayID?) -> String {
        CGConfigureDisplayMirrorOfDisplay(config, retina, kCGNullDirectDisplay)

        var retinaPointWidth = Int32(CGDisplayCopyDisplayMode(retina)?.width ?? 1728)
        if let std = standardRetinaMode {
            CGConfigureDisplayWithDisplayMode(config, retina, std, nil)
            retinaPointWidth = Int32(std.width)
        }
        CGConfigureDisplayOrigin(config, retina, 0, 0)                  // Retina main

        if let asus = asus {
            CGConfigureDisplayMirrorOfDisplay(config, asus, kCGNullDirectDisplay)
            // Same guard as the projector path: restore the ASUS's native mode so
            // a mirror-break fallback (800×600) never survives into the layout.
            if let m = bestMode(asus) { CGConfigureDisplayWithDisplayMode(config, asus, m, nil) }
            CGConfigureDisplayOrigin(config, asus, retinaPointWidth, 0) // extended right
            return "🖥️ Standard: Retina main + ASUS right"
        }
        return "🖥️ Standard: Retina only"
    }

    /// Home rig: enforce the single invariant "nothing mirrors the Retina" while
    /// preserving Victor's exact layout. We touch **only** displays actually in a
    /// mirror set: un-mirror each, restore it to a real mode (breaking a mirror
    /// drops the slave to a fallback like 800×600), and park it just past the
    /// rightmost display we're *not* moving — so the already-extended monitors
    /// keep their precise positions and resolutions. If nothing is mirrored, we
    /// touch nothing at all (the layout stays byte-for-byte as the user left it).
    private func unmirrorHomeDisplays(_ displays: DisplaySet) {
        guard let retina = displays.retina else { return }

        let externals = onlineDisplayIDs().filter { $0 != retina }
        let mirroredExternals = externals.filter { CGDisplayIsInMirrorSet($0) != 0 }
        // Retina needs fixing only if it's the mirror master (which a mirror can
        // also have forced down to 1080p — we restore its native mode then).
        let retinaMirrored = CGDisplayIsInMirrorSet(retina) != 0
        guard !mirroredExternals.isEmpty || retinaMirrored else {
            overlayInfo("Home layout preserved (nothing mirrored)")
            return
        }

        isApplying = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isApplying = false
            }
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            overlayError("CGBeginDisplayConfiguration failed — could not un-mirror home monitors")
            return
        }

        // Retina: only if it was the mirror master — un-mirror + restore native
        // HiDPI (a mirror can force it to 1080p) + keep it main at (0,0).
        if retinaMirrored {
            CGConfigureDisplayMirrorOfDisplay(config, retina, kCGNullDirectDisplay)
            if let native = standardRetinaMode ?? retinaNativeMode(retina) {
                CGConfigureDisplayWithDisplayMode(config, retina, native, nil)
            }
            CGConfigureDisplayOrigin(config, retina, 0, 0)
        }

        // Park each recovered (un-mirrored) display just past the rightmost edge
        // of everything we leave untouched, so we never overlap — or move — the
        // good monitors. A mirror slave has no NSScreen/name (would be misread as
        // a "projector"), which is exactly why we key off the mirror set, not the
        // named list.
        let untouched = ([retina] + externals).filter { !mirroredExternals.contains($0) }
        var x = untouched.map { d -> Int32 in
            if d == retina, retinaMirrored {
                return Int32((standardRetinaMode ?? retinaNativeMode(retina))?.width
                    ?? CGDisplayCopyDisplayMode(retina)?.width ?? 1728)
            }
            return Int32(CGDisplayBounds(d).maxX)
        }.max() ?? 0
        for ext in mirroredExternals {
            CGConfigureDisplayMirrorOfDisplay(config, ext, kCGNullDirectDisplay)
            // Breaking a mirror drops the slave to a fallback (e.g. 800×600), so
            // pin it back to its native/best mode before placing it.
            let mode = bestMode(ext)
            if let mode { CGConfigureDisplayWithDisplayMode(config, ext, mode, nil) }
            CGConfigureDisplayOrigin(config, ext, x, 0)
            x += Int32(mode?.width ?? CGDisplayCopyDisplayMode(ext)?.width ?? 1920)
        }

        let banner = "🖥️ Home: un-mirrored \(mirroredExternals.count) monitor(s), layout preserved"
        if CGCompleteDisplayConfiguration(config, .permanently) == .success {
            overlayInfo(banner)
            DispatchQueue.main.async { [weak self] in self?.onArrangementApplied?(banner) }
        } else {
            overlayError("CGCompleteDisplayConfiguration failed — could not un-mirror home monitors")
        }
    }

    /// The highest-resolution usable mode for an external display (prefers 60 Hz),
    /// used to restore a monitor to full res after breaking its mirror.
    private func bestMode(_ display: CGDirectDisplayID) -> CGDisplayMode? {
        guard let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else { return nil }
        let usable = modes.filter { $0.isUsableForDesktopGUI() }
        func rank(_ m: CGDisplayMode) -> (Int, Int) {
            (m.pixelWidth * m.pixelHeight, abs(m.refreshRate - 60) < 0.5 ? 1 : 0)
        }
        return usable.max { rank($0) < rank($1) }
    }

    /// Best-guess the Retina's native "default" mode when we never captured one
    /// (e.g. the app only ever saw it while mirror-forced to 1080p): the true 2×
    /// Retina mode (`pixelWidth == 2·width`) with the largest backing panel.
    private func retinaNativeMode(_ retina: CGDirectDisplayID) -> CGDisplayMode? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: false] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(retina, opts) as? [CGDisplayMode] else { return nil }
        let retina2x = modes.filter {
            $0.isUsableForDesktopGUI()
                && $0.pixelWidth == 2 * $0.width
                && $0.pixelHeight == 2 * $0.height
        }
        return retina2x.max { $0.pixelWidth < $1.pixelWidth }
    }

    /// Find a real 1920×1080 mode on `display`. Prefers a non-HiDPI mode (1920
    /// backing pixels — a true 1080p signal for the projector) at ~60 Hz; falls
    /// back to any 1920×1080 mode. Includes the low-res duplicate modes that
    /// aren't offered in the default list.
    private func find1080Mode(_ display: CGDirectDisplayID) -> CGDisplayMode? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode] else { return nil }
        let matches = modes.filter { $0.width == 1920 && $0.height == 1080 && $0.isUsableForDesktopGUI() }
        func rank(_ m: CGDisplayMode) -> (Int, Int) {
            let native = (m.pixelWidth == 1920 && m.pixelHeight == 1080) ? 1 : 0    // prefer true 1080p
            let hz60 = abs(m.refreshRate - 60) < 0.5 ? 1 : 0                         // prefer 60 Hz
            return (native, hz60)
        }
        return matches.max { rank($0) < rank($1) }
    }

    // MARK: - Debug helpers

    private func describe(_ scene: Scene?) -> String {
        guard let scene else { return "nil" }
        return "projector=\(scene.projector) asus=\(scene.asus)"
    }

    private func describe(_ d: DisplaySet) -> String {
        func nm(_ id: CGDirectDisplayID?) -> String {
            guard let id else { return "—" }
            return screenName(for: id) ?? "display \(id)"
        }
        return "retina=\(nm(d.retina)) asus=\(nm(d.asus)) projector=\(nm(d.projector))"
    }
}
