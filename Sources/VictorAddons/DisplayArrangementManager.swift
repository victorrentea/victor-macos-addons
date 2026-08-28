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
/// in **two phases**: modes + mirror topology first, then origins (who is main,
/// who sits where) in a separate transaction ~0.6 s later. They cannot share one
/// transaction: when the mirror set changes, macOS recomputes the layout after
/// the mirror lands and silently discards the requested origins — the Epson
/// PU100 bug, where "ASUS primary" reported success yet the Retina stayed main.
/// No external tools, no extra entitlements (reconfiguring displays needs no
/// Screen-Recording permission).
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

    /// A resolved set of the displays we care about at one instant. Roles come
    /// from `DisplayRolePolicy` (pure, unit-tested); this class only feeds it
    /// Quartz facts and acts on the answer.
    private typealias DisplaySet = DisplayRolePolicy.Resolution

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
    /// How many times the current arrangement has been re-applied because the
    /// verification pass found macOS had not honoured it. Reset on every fresh
    /// evaluation; capped by `maxApplyAttempts`.
    private var applyAttempt = 0
    private let maxApplyAttempts = 3
    /// Guards against re-entering the un-mirror probe in a loop.
    private var probeInFlight = false

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
        notifyUnknownExternal(unknownExternalPresent(displays))
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
    private func evaluateAndApply(force: Bool, afterProbe: Bool = false) {
        let displays = resolveDisplays()

        // Anonymous displays: macOS swept one or more displays into a mirror
        // set, and a mirror slave has no NSScreen — hence no name — so we cannot
        // tell the ASUS from the room TV. Guessing is what produced the
        // 2026-08-27 incident (the ASUS was taken for the projector and left
        // mirroring). Break every mirror, let the names come back, ask again.
        if displays.needsUnmirrorProbe && !afterProbe {
            // The signal must not wait for the probe: an unattributable display
            // is presentation enough.
            notifyUnknownExternal(unknownExternalPresent(displays))
            let anon = displays.unidentified.map(String.init).joined(separator: ",")
            overlayInfo("Anonymous mirror slave(s) [\(anon)] — breaking mirrors to identify them")
            breakAllMirrorsAndReresolve()
            return
        }

        captureStandardRetinaModeIfNeeded(displays)
        // Always refresh the presentation signal first — even when the arrange
        // scene is unchanged or suppressed below.
        notifyUnknownExternal(unknownExternalPresent(displays))

        let target = scene(for: displays)
        if !force, target == lastScene {
            overlayInfo("Display change ignored (scene unchanged: \(describe(target)))")
            return
        }
        lastScene = target
        applyAttempt = 0

        // A familiar multi-display rig: when KNOWN non-ASUS externals (home
        // monitors / TV) are present, Victor's own layout — the exact positions
        // and resolutions he set — is kept **verbatim**. The ONE invariant we
        // enforce is that no home display *mirrors* the Retina; we touch only a
        // display actually caught in a mirror set (see `unmirrorHomeDisplays`),
        // never the ones already extended. A venue (unknown projector) never has
        // these connected. Even the manual "🖥️ Arrange Monitors" (force) only
        // breaks stray mirroring here — it does not re-shuffle the home layout.
        if displays.hasKnownExternal {
            unmirrorHomeDisplays(displays)
            return
        }

        apply(scene: target, displays: displays)
    }

    /// Break **every** mirror set, then re-resolve ~0.9 s later. The only way to
    /// give an anonymous mirror slave its name back is to take it out of the
    /// mirror set: `NSScreen` then lists it again. The follow-up evaluation is
    /// forced, because the scene key can easily look unchanged while the actual
    /// roles were wrong.
    private func breakAllMirrorsAndReresolve() {
        guard !probeInFlight else { return }
        probeInFlight = true
        isApplying = true

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            overlayError("CGBeginDisplayConfiguration failed — could not un-mirror to identify displays")
            probeInFlight = false
            isApplying = false
            return
        }
        for id in onlineDisplayIDs() where CGDisplayIsInMirrorSet(id) != 0 {
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            // Breaking a mirror drops the ex-slave to a fallback mode (800×600),
            // and the probe must not be the thing that leaves it there — the
            // follow-up may well decide to keep the layout as it is.
            if CGDisplayIsBuiltin(id) == 0, let m = bestMode(id) {
                CGConfigureDisplayWithDisplayMode(config, id, m, nil)
            }
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        guard result == .success else {
            overlayError("CGCompleteDisplayConfiguration failed (\(result.rawValue)) — could not un-mirror to identify displays")
            probeInFlight = false
            isApplying = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.probeInFlight = false
            self.isApplying = false
            self.evaluateAndApply(force: true, afterProbe: true)
        }
    }

    /// The presentation signal: some connected display cannot be attributed to
    /// Victor's own gear. An **anonymous mirror slave counts** — staying silent
    /// through a real room-TV session is a worse failure than arming the warning
    /// while the ASUS alone happens to be mirrored.
    private func unknownExternalPresent(_ d: DisplaySet) -> Bool {
        d.projector != nil || !d.extraExternals.isEmpty || !d.unidentified.isEmpty
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
    /// Backs the "🖥️ Arrange Monitors" menu item.
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
        let extras = (d.extraExternals + d.unidentified).map { "\(nm($0))" }.joined(separator: ",")
        return "{"
            + "\"retina\":\(nm(d.retina)),"
            + "\"asus\":\(nm(d.asus)),"
            + "\"projector\":\(nm(d.projector)),"
            + "\"otherExternals\":[\(extras)],"
            + "\"anonymousMirrorSlaves\":\(d.unidentified.count),"
            + "\"scene\":\"\(s.projector ? "projector" : "standard")\","
            + "\"retinaMode\":\(retinaModeStr),"
            + "\"retina1080Available\":\(has1080),"
            + "\"registered\":\(reconfigureRegistered)"
            + "}"
    }

    // MARK: - Role resolution

    private func resolveDisplays() -> DisplaySet {
        // Learn the names of everything currently visible, so a display that
        // gets mirrored (and loses its NSScreen) can still be recognised later.
        DisplayNameCache.learn()
        let facts = onlineDisplayIDs().map { id in
            DisplayFacts(id: id,
                         isBuiltin: CGDisplayIsBuiltin(id) != 0,
                         name: screenName(for: id),
                         isMirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
        let known = knownDisplays
        return DisplayRolePolicy.resolve(facts) { known.isKnown(name: $0) }
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Cache-backed so a mirror slave (no `NSScreen`) still reports its name.
    private func screenName(for id: CGDirectDisplayID) -> String? {
        KnownDisplays.name(for: id)
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

        // Phase 1 — display modes + mirror topology ONLY. Origins must not ride
        // in this transaction: when the mirror set changes, macOS recomputes the
        // layout after the mirror lands and silently discards the requested
        // origins (the Epson PU100 bug — "ASUS primary" reported success, yet
        // the Retina stayed main). Origins get their own transaction in phase 2.
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            overlayError("CGBeginDisplayConfiguration failed — arrangement not applied")
            scheduleApplyingReset()
            return
        }

        let banner: String
        if scene.projector, displays.projector != nil, displays.retina != nil {
            banner = configureProjectorModes(config: config, displays: displays)
        } else if displays.retina != nil {
            banner = configureStandardModes(config: config, displays: displays)
        } else {
            _ = CGCancelDisplayConfiguration(config)
            scheduleApplyingReset()
            return
        }

        let result = CGCompleteDisplayConfiguration(config, .permanently)
        guard result == .success else {
            overlayError("CGCompleteDisplayConfiguration failed (\(result.rawValue)) — \(banner)")
            scheduleApplyingReset()
            return
        }

        // Phase 2 — origins (which display is main, who sits where), after the
        // mirror/mode transaction settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.applyOrigins(scene: scene, displays: displays, banner: banner)
            self.scheduleApplyingReset()
        }
    }

    /// Phase 3 — **check that macOS actually did it.** Quartz reports success
    /// for a configuration it then quietly recomputes (the Epson PU100 bug), and
    /// a display that is still settling (or flapping, as the ASUS did on
    /// 2026-08-27) can swallow the origins outright. So we read the live layout
    /// back 1.5 s later and re-apply if it isn't what we asked for, up to
    /// `maxApplyAttempts`. Deliberately short-lived: a manual re-layout Victor
    /// makes seconds later is still left alone, because verification only runs
    /// in the few seconds following an apply we ourselves performed.
    private func scheduleVerification(scene: Scene, displays: DisplaySet, banner: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.verifyAndRetry(scene: scene, displays: displays, banner: banner)
        }
    }

    private func verifyAndRetry(scene: Scene, displays: DisplaySet, banner: String) {
        // Hardware moved on: a fresh evaluation is already queued, don't fight it.
        let live = resolveDisplays()
        guard live.retina == displays.retina,
              live.asus == displays.asus,
              live.projector == displays.projector else {
            overlayInfo("Arrangement verification skipped — displays changed since applying")
            return
        }

        guard let problem = mismatch(scene: scene, displays: displays) else {
            overlayInfo("Display arrangement verified: \(banner)")
            return
        }
        guard applyAttempt + 1 < maxApplyAttempts else {
            overlayError("Display arrangement NOT honoured by macOS after \(applyAttempt + 1) attempts "
                + "(\(problem)) — \(banner). Use 🖥️ Arrange Monitors to retry.")
            return
        }
        applyAttempt += 1
        overlayInfo("Display arrangement not honoured (\(problem)) — re-applying "
            + "(attempt \(applyAttempt + 1)/\(maxApplyAttempts))")
        apply(scene: scene, displays: displays)
    }

    /// `nil` when the live layout is what we asked for; otherwise the first
    /// broken invariant, in words, for the log.
    private func mismatch(scene: Scene, displays: DisplaySet) -> String? {
        guard let retina = displays.retina else { return nil }
        if scene.projector {
            if let projector = displays.projector, CGDisplayMirrorsDisplay(projector) != retina {
                return "projector is not mirroring the Retina"
            }
            if find1080Mode(retina) != nil, let mode = CGDisplayCopyDisplayMode(retina), mode.width != 1920 {
                return "Retina is at \(mode.width)×\(mode.height), not 1920×1080"
            }
            if let asus = displays.asus {
                if CGDisplayIsInMirrorSet(asus) != 0 { return "the ASUS is still mirroring" }
                if CGMainDisplayID() != asus { return "the ASUS is not the main display" }
            }
        } else {
            if CGDisplayIsInMirrorSet(retina) != 0 { return "the Retina is still in a mirror set" }
            if CGMainDisplayID() != retina { return "the Retina is not the main display" }
            if let asus = displays.asus, CGDisplayIsInMirrorSet(asus) != 0 {
                return "the ASUS is still mirroring"
            }
        }
        return nil
    }

    /// Keep swallowing our own reconfiguration callbacks briefly after the last
    /// transaction settles.
    private func scheduleApplyingReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isApplying = false
        }
    }

    /// Phase 2: place the displays. The display whose origin lands at (0,0)
    /// becomes main. Runs in its own transaction (see `apply`).
    private func applyOrigins(scene: Scene, displays: DisplaySet, banner: String) {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            overlayError("CGBeginDisplayConfiguration failed — origins not applied (\(banner))")
            return
        }

        // Phase 1's mode change is live by now, so the Retina's current mode is
        // the actual point width being extended next to.
        let retinaPointWidth = Int32(displays.retina.flatMap { CGDisplayCopyDisplayMode($0)?.width } ?? 1920)

        var rightEdge: Int32 = 0
        if scene.projector, let asus = displays.asus, let retina = displays.retina {
            CGConfigureDisplayOrigin(config, asus, 0, 0)                   // (0,0) ⇒ main
            CGConfigureDisplayOrigin(config, retina, -retinaPointWidth, 0) // to ASUS's left
            rightEdge = Int32(CGDisplayCopyDisplayMode(asus)?.width ?? 1920)
        } else if let retina = displays.retina {
            CGConfigureDisplayOrigin(config, retina, 0, 0)                 // Retina main
            rightEdge = retinaPointWidth
            if let asus = displays.asus {
                CGConfigureDisplayOrigin(config, asus, retinaPointWidth, 0) // extended right
                rightEdge += Int32(CGDisplayCopyDisplayMode(asus)?.width ?? 1920)
            }
        }
        // Any further unknown external (a second venue screen) is parked to the
        // right rather than left stacked on top of the others at (0,0).
        for extra in displays.extraExternals {
            CGConfigureDisplayOrigin(config, extra, rightEdge, 0)
            rightEdge += Int32(CGDisplayCopyDisplayMode(extra)?.width ?? 1920)
        }

        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result == .success {
            overlayInfo("Display arrangement applied: \(banner)")
            onArrangementApplied?(banner)
            scheduleVerification(scene: scene, displays: displays, banner: banner)
        } else {
            overlayError("CGCompleteDisplayConfiguration failed on origins (\(result.rawValue)) — \(banner)")
        }
    }

    /// Projector present (phase 1): Retina→1080p, mirrored by the projector;
    /// ASUS + any extra external un-mirrored and pinned to their native mode.
    private func configureProjectorModes(config: CGDisplayConfigRef,
                                         displays: DisplaySet) -> String {
        guard let retina = displays.retina, let projector = displays.projector else { return "🖥️ —" }
        let asus = displays.asus
        if let mode = find1080Mode(retina) {
            CGConfigureDisplayWithDisplayMode(config, retina, mode, nil)
        } else {
            overlayError("No 1920×1080 mode on the Retina — mirroring at current mode")
        }

        // Projector mirrors the Retina (shares its bounds — do not place it).
        CGConfigureDisplayMirrorOfDisplay(config, projector, retina)

        // Every other external is taken out of the mirror set explicitly. macOS
        // sweeps whatever is already attached into the new display's mirror set
        // on hot-plug, and anything we don't name here stays mirrored.
        for extra in displays.extraExternals {
            CGConfigureDisplayMirrorOfDisplay(config, extra, kCGNullDirectDisplay)
            if let m = bestMode(extra) { CGConfigureDisplayWithDisplayMode(config, extra, m, nil) }
        }

        if let asus = asus {
            CGConfigureDisplayMirrorOfDisplay(config, asus, kCGNullDirectDisplay)
            // Un-mirroring drops a former mirror slave to a fallback mode (e.g.
            // 800×600); if macOS swept the ASUS into the mirror set when the
            // projector appeared, breaking that mirror leaves it there. Pin it
            // back to its native mode so it isn't primary at 800×600.
            if let m = bestMode(asus) { CGConfigureDisplayWithDisplayMode(config, asus, m, nil) }
            return "🖥️ Projector: mirror + ASUS primary (Retina 1080p left)"
        } else {
            return "🖥️ Projector: mirrored (Retina 1080p)"
        }
    }

    /// No projector (phase 1): Retina un-mirrored at its native mode; ASUS and
    /// any extra external un-mirrored + pinned to their native mode.
    private func configureStandardModes(config: CGDisplayConfigRef,
                                        displays: DisplaySet) -> String {
        guard let retina = displays.retina else { return "🖥️ —" }
        let asus = displays.asus
        CGConfigureDisplayMirrorOfDisplay(config, retina, kCGNullDirectDisplay)

        if let std = standardRetinaMode {
            CGConfigureDisplayWithDisplayMode(config, retina, std, nil)
        }

        for extra in displays.extraExternals {
            CGConfigureDisplayMirrorOfDisplay(config, extra, kCGNullDirectDisplay)
            if let m = bestMode(extra) { CGConfigureDisplayWithDisplayMode(config, extra, m, nil) }
        }

        if let asus = asus {
            CGConfigureDisplayMirrorOfDisplay(config, asus, kCGNullDirectDisplay)
            // Same guard as the projector path: restore the ASUS's native mode so
            // a mirror-break fallback (800×600) never survives into the layout.
            if let m = bestMode(asus) { CGConfigureDisplayWithDisplayMode(config, asus, m, nil) }
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
            + (d.extraExternals.isEmpty ? "" : " extra=\(d.extraExternals.map { nm($0) }.joined(separator: ","))")
            + (d.unidentified.isEmpty ? "" : " anonymous=\(d.unidentified.count)")
    }
}
