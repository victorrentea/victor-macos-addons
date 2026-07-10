import AppKit
import QuartzCore

/// Break countdown "watch" overlay: a draggable, resizable, mouse-interactive
/// panel showing a big red seven-segment MM:SS countdown over a frosted-glass
/// (blurred) 60%-opaque black background, the finish time in two timezones, and
/// small controls (+1 / +3 / +5 / pause / close). Hovering shows resize cursors
/// at the corners and a pointer over the buttons; the body keeps the plain arrow.
/// On expiry it returns to the retina (if dragged elsewhere), gongs twice, blinks
/// twice, and fades out. Unlike OverlayPanel, this panel accepts mouse events.

// MARK: - Controller

final class BreakTimerController {
    static let aspect: CGFloat = 1.63         // width / height; chosen so the height-fit digit block
                                              // spans exactly [1.5m, width-1.5m] (the +50% side margins)

    static let minWidth: CGFloat = 180

    // Geometry for the fullscreen-on-idle behavior. (At normal size the backdrop is
    // hover-driven; while enlarged-on-idle it stays always black — see `activityTick`.)
    private static let fullscreenIdleSeconds: CFTimeInterval = 120    // total (mouse+keyboard) idle → enlarge
    private static let enlargeFraction: CGFloat = 0.85               // big frame fills 85% of the screen
    private static let enlargeAnimationDuration: TimeInterval = 0.3   // enlarge/restore animation

    /// Seconds from the start of `50_gong.mp3` to its audible strike. The clip
    /// opens with ~1.0s of near-silence and its RMS/absolute peak (the loud
    /// "BONG") lands at ~1.02s in (measured with ffmpeg). The expiry shake is
    /// delayed by this so the watch's most violent wobble coincides with the
    /// strike you hear — not with the silent lead-in (which made the shake peak
    /// a full second early).
    private static let gongStrikePeak: Double = 1.02

    private var panel: BreakTimerPanel?
    private var view: BreakTimerView?

    private var remaining = 0                  // seconds
    private var paused = false
    private var freezeNow: Date?              // wall-clock frozen while paused
    private var timer: Timer?
    private var blinkTimer: Timer?            // drives the expiry blink
    private var shakeTimer: Timer?            // drives the whole-window expiry shake
    private var activityTimer: Timer?         // toggles the background while the user works
    private var bgView: NSView?              // opaque backdrop, faded in/out
    private var bgOpaque = true              // current backdrop state
    private var epoch = 0                      // invalidates in-flight expiry blocks

    // Title + size for the NEXT fresh window. The menu opens a full-size "BREAK";
    // clicking a floating ☕ opens a half-size "UNTIL BREAK". Both persist so a
    // redeploy mid-break resumes with the right label and size.
    private var titleText = "BREAK"
    private var nextFreshScale: CGFloat = 1.0

    /// Whether a break overlay is currently on screen (used to avoid a ☕ click
    /// disrupting a countdown that's already running).
    var isShowing: Bool { panel != nil }

    // Fullscreen-on-idle: after `fullscreenIdleSeconds` of total inactivity the
    // panel grows to `enlargeFraction` of its screen; any input restores it.
    private var isEnlarged = false
    private var savedFrame: NSRect?           // the user's frame, restored on enlarge → normal

    // The single finish-time line shows a user-pickable country; the pick is
    // day-scoped (resets to Romania each new day). Clicking the flag opens the picker.
    private var selectedCountry = BreakCountry.loadSelected()

    /// Apply a dropdown pick: persist it and repaint the second line in the new
    /// country's flag + timezone.
    private func selectCountry(_ c: BreakCountry) {
        selectedCountry = c
        c.saveSelected()
        view?.selectedCountryTZ = c.tz
        refresh()
    }

    /// Headless test hook (`/test/break/picker`): open the country picker on the
    /// live overlay, optionally pre-filtered. No-op if no break is showing.
    func openCountryPicker(query: String?) {
        view?.openPickerForTest(query: query)
    }

    /// Fired when a break *ends* — i.e. whenever the window is closed: the ✕
    /// button, the countdown expiring (which auto-closes after the gong), or a
    /// programmatic stop. NOT fired by re-opening or +minutes (those reuse the
    /// window via start(), never close()). Drives the menu's "Resumed Xm ago"
    /// clock (time since the last break ended).
    var onEnded: (() -> Void)?

    /// (Re)start the countdown at `minutes`. Reuses the existing window in place
    /// (keeping its position & size); a fresh window opens top-right at 25% width.
    func start(minutes: Int, title: String = "BREAK", sizeScale: CGFloat = 1.0) {
        epoch += 1
        blinkTimer?.invalidate(); blinkTimer = nil
        remaining = max(0, minutes) * 60
        paused = false
        freezeNow = nil
        titleText = title
        nextFreshScale = sizeScale
        // Day-scoped: first start of the day auto-picks "where I am now" (by the
        // Mac's live timezone) and locks it in; later starts today reuse it.
        selectedCountry = BreakCountry.autoSelectForToday()

        let view = ensureWindow()
        view.titleText = title
        view.selectedCountryTZ = selectedCountry.tz
        view.setDigitsVisible(true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()

        startTicking()
        startActivityMonitor()
        refresh()
        persist()
    }

    func addMinutes(_ m: Int) {
        guard panel != nil else { return }
        epoch += 1                            // cancel any pending expiry sequence
        blinkTimer?.invalidate(); blinkTimer = nil
        remaining = max(0, remaining + m * 60)
        if paused { freezeNow = Date() }      // re-anchor frozen finish time
        view?.setDigitsVisible(true)
        panel?.alphaValue = 1
        if !paused { startTicking() }
        refresh()
        persist()
    }

    func togglePause() {
        guard panel != nil else { return }
        paused.toggle()
        if paused {
            freezeNow = Date()
            timer?.invalidate(); timer = nil
        } else {
            freezeNow = nil
            startTicking()
        }
        refresh()
        persist()
    }

    func close() {
        epoch += 1                                       // cancels pending gong/expiry blocks
        if panel != nil { onEnded?() }                   // a break was showing → (re)start the "resumed" clock
        SoundManager.shared.stopOverlapping("50_gong.mp3")  // interrupt a gong in progress
        timer?.invalidate(); timer = nil
        blinkTimer?.invalidate(); blinkTimer = nil
        shakeTimer?.invalidate(); shakeTimer = nil
        activityTimer?.invalidate(); activityTimer = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        bgView = nil
        // Reset idle-driven state so a future open starts normal-sized.
        isEnlarged = false
        savedFrame = nil
        // The view sets custom cursors (open-hand to move, pointer over buttons,
        // resize at corners) imperatively; restore the standard arrow so closing
        // the timer never leaves a hand/resize cursor stuck on screen.
        NSCursor.arrow.set()
        clearPersisted()
    }

    // MARK: - Persistence (survive an app redeploy mid-break)

    private static let kFinishAt = "BreakTimer.finishAt"
    private static let kPausedRemaining = "BreakTimer.pausedRemaining"
    private static let kTitle = "BreakTimer.title"
    private static let kScale = "BreakTimer.scale"

    private func persist() {
        let d = UserDefaults.standard
        d.set(titleText, forKey: Self.kTitle)
        d.set(Double(nextFreshScale), forKey: Self.kScale)
        if paused {
            d.removeObject(forKey: Self.kFinishAt)
            d.set(remaining, forKey: Self.kPausedRemaining)
        } else {
            d.set(Date().addingTimeInterval(TimeInterval(remaining)), forKey: Self.kFinishAt)
            d.removeObject(forKey: Self.kPausedRemaining)
        }
    }

    private func clearPersisted() {
        UserDefaults.standard.removeObject(forKey: Self.kFinishAt)
        UserDefaults.standard.removeObject(forKey: Self.kPausedRemaining)
        UserDefaults.standard.removeObject(forKey: Self.kTitle)
        UserDefaults.standard.removeObject(forKey: Self.kScale)
    }

    /// On launch, resume a countdown that was running/paused when the app quit.
    func resumeIfNeeded() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.kPausedRemaining) != nil {
            let rem = d.integer(forKey: Self.kPausedRemaining)
            if rem > 0 { resume(remaining: rem, paused: true) } else { clearPersisted() }
        } else if let finishAt = d.object(forKey: Self.kFinishAt) as? Date {
            let rem = Int(finishAt.timeIntervalSinceNow.rounded())
            if rem > 0 { resume(remaining: rem, paused: false) } else { clearPersisted() }
        }
    }

    private func resume(remaining rem: Int, paused isPaused: Bool) {
        epoch += 1
        blinkTimer?.invalidate(); blinkTimer = nil
        remaining = rem
        paused = isPaused
        freezeNow = isPaused ? Date() : nil
        // Restore the label + size the break had before the redeploy/restart.
        titleText = UserDefaults.standard.string(forKey: Self.kTitle) ?? "BREAK"
        let s = UserDefaults.standard.double(forKey: Self.kScale)
        nextFreshScale = s > 0 ? CGFloat(s) : 1.0
        let v = ensureWindow()
        v.titleText = titleText
        v.setDigitsVisible(true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        if !isPaused { startTicking() }
        startActivityMonitor()
        refresh()
    }

    /// Chaotic 2D shake for the expiry: violent at each gong strike, then decaying
    /// fully to still as that strike's sound fades out (no residual jitter). Drives
    /// the WHOLE panel's frame origin (not a content-layer transform) so the entire
    /// window — black backdrop, digits and all — jitters as one rigid unit, instead
    /// of just the text moving inside a static box.
    private func startExpiryShake(totalDuration: Double, strikeAt: [Double]) {
        guard let panel else { return }
        shakeTimer?.invalidate()
        let base = panel.frame.origin                  // home position; every frame offsets from this
        let peak: CGFloat = 36                         // same peak amplitude as before
        let k = 2.4                                    // decay rate ~ the gong's loud fade
        func env(_ t: Double) -> Double {
            var bump = 0.0
            for s in strikeAt where t >= s { bump += exp(-k * (t - s)) }
            return Double(peak) * min(1.0, bump)       // decays to 0 → still as the gong fades
        }
        let start = Date()
        let myEpoch = epoch
        var lastOffset: NSPoint?
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tm in
            guard let self, self.epoch == myEpoch, let panel = self.panel else { tm.invalidate(); return }
            let t = Date().timeIntervalSince(start)
            guard t < totalDuration else {
                tm.invalidate()
                panel.setFrameOrigin(base)             // settle exactly home
                return
            }
            let e = env(t)
            // incommensurate frequencies on X and Y → chaotic, non-axis-aligned wobble
            let dx = (e * (0.7 * sin(t * 2 * .pi * 7.3) + 0.3 * sin(t * 2 * .pi * 13.1 + 0.7))).rounded()
            let dy = (e * (0.7 * sin(t * 2 * .pi * 9.7 + 1.1) + 0.3 * sin(t * 2 * .pi * 5.3 + 2.0))).rounded()
            let off = NSPoint(x: dx, y: dy)
            if off == lastOffset { return }            // no visible change (quiet gap) → skip the move
            lastOffset = off
            panel.setFrameOrigin(NSPoint(x: base.x + dx, y: base.y + dy))
        }
        RunLoop.main.add(timer, forMode: .common)
        shakeTimer = timer
    }

    // MARK: - Activity-driven backdrop

    /// The opaque black backdrop is shown by DEFAULT and clears ONLY while the
    /// cursor is hovering over the timer panel: hover in → it fades fully away (so
    /// you can see the screen underneath, only the outlined digits remain), hover
    /// out → it fades back to fully opaque. One smooth fade per transition, so it
    /// never flickers. EXCEPTION: while the panel is enlarged-on-idle it stays
    /// always black (a resting cursor sits over the big panel, so hover would
    /// otherwise clear it — see `activityTick`).
    ///
    /// The same tick also drives the fullscreen-on-idle behavior, but from TOTAL
    /// inactivity (`systemIdleSeconds`, mouse+keyboard), so any input — even
    /// keystrokes or a mouse move on another screen — restores the original size.
    private func startActivityMonitor() {
        activityTimer?.invalidate()
        // Default state: opaque black backdrop. It only clears while the cursor
        // hovers over the panel (handled per-tick below).
        bgOpaque = true
        bgView?.alphaValue = 1
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.activityTick() }
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
    }

    private func activityTick() {
        // --- Fullscreen on total inactivity; any input restores ---
        if Self.systemIdleSeconds() >= Self.fullscreenIdleSeconds {
            enlargeIfNeeded(on: panelScreen())
        } else {
            restoreIfNeeded()
        }

        // --- Backdrop: black by default, transparent only while hovering the panel ---
        // While enlarged-on-idle, keep it ALWAYS black: the big panel covers ~85% of
        // the screen, so a resting cursor sits "over" it and would otherwise fade the
        // backdrop away. Only the normal-size timer peeks through on hover.
        let hovering = panel?.frame.contains(NSEvent.mouseLocation) ?? false
        setBackgroundOpaque(isEnlarged || !hovering)
    }

    /// The screen the timer panel is currently on. `panel.screen` is the most-
    /// overlapping screen; if it's nil (panel dragged off-screen) fall back to the
    /// screen containing the panel's center, then to the retina/built-in display.
    private func panelScreen() -> NSScreen {
        if let s = panel?.screen { return s }
        if let f = panel?.frame,
           let s = Self.screen(containing: NSPoint(x: f.midX, y: f.midY)) { return s }
        return AppDelegate.findRetinaScreen()
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// Grow the panel to a centered ~85% frame on its screen (saving the user's
    /// current frame first). Idempotent — does nothing while already enlarged.
    private func enlargeIfNeeded(on screen: NSScreen) {
        guard !isEnlarged, let panel else { return }
        isEnlarged = true
        savedFrame = panel.frame
        let aspect = panel.frame.height > 0 ? panel.frame.width / panel.frame.height : Self.aspect
        let big = BreakTimerModel.enlargedFrame(in: screen.frame, aspect: aspect, fraction: Self.enlargeFraction)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.enlargeAnimationDuration
            panel.animator().setFrame(big, display: true)
        }
    }

    /// Shrink back to the user's saved frame. Idempotent — does nothing unless
    /// currently enlarged.
    private func restoreIfNeeded() {
        guard isEnlarged, let panel else { return }
        isEnlarged = false
        let target = savedFrame ?? Self.defaultFrame()
        savedFrame = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.enlargeAnimationDuration
            panel.animator().setFrame(target, display: true)
        }
    }

    private func setBackgroundOpaque(_ opaque: Bool) {
        guard let bgView, opaque != bgOpaque else { return }
        bgOpaque = opaque
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            bgView.animator().alphaValue = opaque ? 1.0 : 0.0
        }
    }

    /// Seconds since the last user input of any kind (mouse or keyboard).
    private static func systemIdleSeconds() -> CFTimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .leftMouseDragged, .keyDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 999
    }

    // MARK: - Internals

    private func ensureWindow() -> BreakTimerView {
        if let view { return view }
        let frame = Self.defaultFrame(scale: nextFreshScale)
        let panel = BreakTimerPanel(contentRect: frame)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]

        // Opaque rounded backdrop on its own layer, so it can fade in/out on the
        // GPU (no per-frame redraw, no flicker).
        let bg = NSView(frame: container.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        bg.layer?.cornerRadius = frame.height * 0.05
        bg.layer?.masksToBounds = true
        container.addSubview(bg)

        let view = BreakTimerView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.onClose = { [weak self] in self?.close() }
        view.onTogglePause = { [weak self] in self?.togglePause() }
        view.onAdd = { [weak self] m in self?.addMinutes(m) }
        view.selectedCountryTZ = selectedCountry.tz
        view.onSelectCountry = { [weak self] c in self?.selectCountry(c) }
        container.addSubview(view)

        panel.contentView = container
        self.panel = panel
        self.bgView = bg
        self.view = view
        return view
    }

    private func startTicking() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !paused else { return }
        remaining -= 1
        if remaining <= 0 {
            remaining = 0
            refresh()
            beginExpiry()
        } else {
            refresh()
            // Re-persist every ~5s so a hard kill always leaves a fresh snapshot to
            // resume from. (The absolute finishAt is stable, but this also keeps the
            // store warm and covers any future per-tick state.)
            if remaining % 5 == 0 { persist() }
        }
    }

    private func refresh() {
        guard let view else { return }
        let basis = (paused ? freezeNow : nil) ?? Date()
        view.update(
            digits: BreakTimerModel.format(remaining: remaining),
            finishText: BreakTimerModel.finishLabel(now: basis, remaining: remaining, timeZone: selectedCountry.timeZone),
            flag: selectedCountry.flag,
            paused: paused
        )
    }

    /// At zero: two gong strikes, each shaking the watch left↔right to simulate
    /// the gong's vibration, then close.
    private func beginExpiry() {
        timer?.invalidate(); timer = nil
        clearPersisted()
        // If the timer was dragged onto another display (e.g. the external monitor
        // during a course), bring it home to the retina before the gong + blink —
        // the retina is what's projected to the room, so "break's over!" lands where
        // everyone can see it, and it never expires forgotten on a side monitor.
        returnToRetinaIfNeeded()
        let myEpoch = epoch
        // Play the FULL gong (exact same mp3 as tablet effect #50 — not a clip),
        // then the second strike after the first finishes.
        let gong = SoundManager.shared.soundDuration("50_gong.mp3") ?? 8.6

        SoundManager.shared.playOverlapping("50_gong.mp3")   // strike 1 (full)
        // One continuous chaotic shake spanning both strikes. Each strike's audible
        // "BONG" lands `gongStrikePeak` (~1.02s) into its clip, so peak the shake
        // there — not at t=0 / t=gong (the silent lead-in), which desynced the
        // wobble from the sound.
        let peak = Self.gongStrikePeak
        startExpiryShake(totalDuration: 2 * gong, strikeAt: [peak, gong + peak])
        DispatchQueue.main.asyncAfter(deadline: .now() + gong) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            SoundManager.shared.playOverlapping("50_gong.mp3")   // strike 2 (full)
            // Auto-close only after this FINAL strike has fully rung out, then
            // close()'s stopOverlapping is a clean no-op instead of hard-cutting
            // the decaying tail ("truncated at the end"). `playOverlapping` shifts
            // the actual audio start later by the Bluetooth wake-up compensation
            // (0 on wired/built-in; ~0.8s on a BT speaker — the workshop case), so
            // wait gong + comp + a small margin measured from strike 2, not a fixed
            // 2*gong from expiry-start.
            let comp = SoundTimingConfig.shared.currentBluetoothCompensation
            DispatchQueue.main.asyncAfter(deadline: .now() + gong + comp + 0.6) { [weak self] in
                guard let self, self.epoch == myEpoch else { return }
                self.close()
            }
        }
    }

    /// Move the panel back to its default spot on the built-in retina display when
    /// it currently lives on any other screen (or off-screen). No-op when already on
    /// the retina, so a timer left in place stays put.
    private func returnToRetinaIfNeeded() {
        guard let panel else { return }
        let retinaID = Self.displayID(of: AppDelegate.findRetinaScreen())
        if Self.displayID(of: panel.screen) == retinaID { return }   // already home
        isEnlarged = false            // reset idle-enlarge bookkeeping…
        savedFrame = nil              // …the default frame replaces any saved one
        panel.setFrame(Self.defaultFrame(), display: true)
    }

    private static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func defaultFrame(scale: CGFloat = 1.0) -> NSRect {
        // Always the laptop's built-in retina display — that's what's projected to
        // the room. The macOS *primary* display (origin .zero) or NSScreen.main (the
        // focused screen) may be an external monitor when one is set as main during
        // a course, which would open the timer on the wrong screen.
        let f = AppDelegate.findRetinaScreen().frame
        // ~29% of screen width, tucked into the top-right corner with small gaps
        // (hugs the edges). `scale` shrinks a fresh window — the ☕-triggered
        // "until break" timer opens at 50%.
        let w = f.width * 0.29 * max(0.1, scale)
        let h = w / aspect
        let x = f.maxX - w - f.width * 0.02
        let y = f.maxY - f.height * 0.035 - h
        return NSRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Panel

final class BreakTimerPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false        // drag handled by the view
        acceptsMouseMovedEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    // A non-activating panel can become key (so our cursor management is honored
    // on hover) without activating the app or stealing the user's keyboard focus.
    override var canBecomeKey: Bool { true }
}

// MARK: - Buttons / corners

enum BreakButtonKind { case close, pause }
private enum ResizeCorner { case bottomLeft, bottomRight, topLeft, topRight }
private enum DragMode { case none, move, resize(ResizeCorner), button(BreakButtonKind) }

// MARK: - View

final class BreakTimerView: NSView {
    var onClose: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onAdd: ((Int) -> Void)?

    private var digits = "00:00"
    private var finishText = ""
    private var flag = BreakCountry.romania.flag          // the single finish line's flag
    private var paused = false
    private var digitsVisible = true
    /// The big blinking title above the digits. "BREAK" for a menu-started timer,
    /// "UNTIL BREAK" for the one auto-started by clicking a floating ☕.
    var titleText = "BREAK" { didSet { needsDisplay = true } }

    // Country dropdown: the finish line's flag is a click target. The hit rect is
    // recomputed each draw; picking from the dropdown calls back out.
    var selectedCountryTZ = BreakCountry.romania.tz       // preselected in the picker
    var onSelectCountry: ((BreakCountry) -> Void)?
    private var flagRect: NSRect = .zero
    private let countryPicker = CountryPicker()

    private var dragMode: DragMode = .none
    private var dragStartMouse = NSPoint.zero
    private var dragStartFrame = NSRect.zero
    private var pressedButton: BreakButtonKind?
    private var scrollAccum: CGFloat = 0      // precise-scroll accumulator while grabbing
    private var scrollTap: CFMachPort?        // consumes the wheel while pressed
    private var scrollTapSource: CFRunLoopSource?

    // Red LED look — colors sampled from the reference: a deep red for lit
    // segments and a solid very-dark red for the unlit (ghost) segments.
    private static let lit = NSColor(calibratedRed: 0.847, green: 0.196, blue: 0.224, alpha: 1.0)
    private static let ghost = NSColor(calibratedRed: 0.137, green: 0.031, blue: 0.039, alpha: 1.0)

    // The colon dots live on their own layer so they can pulse gently (1.0↔0.5
    // every second) on the GPU, independent of the digit redraws. The "BREAK"
    // title sits on its own layer too and blinks (1.0↔0.0) at the SAME rate —
    // both animations are added back-to-back so they stay in phase.
    private let colonLayer = CAShapeLayer()
    private let titleLayer = CALayer()
    private var blinkPaused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        colonLayer.fillColor = Self.lit.cgColor
        colonLayer.strokeColor = nil          // halo is a symmetric shadow, not a stroke
        colonLayer.lineWidth = 0
        colonLayer.shadowColor = NSColor.black.cgColor
        colonLayer.shadowOffset = .zero        // equal thickness on all sides
        colonLayer.shadowOpacity = 1
        colonLayer.add(Self.makeBlink(to: 0.5), forKey: "pulse")   // gentle colon pulse
        layer?.addSublayer(colonLayer)
        titleLayer.contentsGravity = .resizeAspect
        titleLayer.add(Self.makeBlink(to: 0.5), forKey: "pulse")   // BREAK blink, same as colon
        layer?.addSublayer(titleLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One 1s blink/pulse cycle (0.5s down + 0.5s up), used by both the colon and
    /// the BREAK title so they share an identical cadence and phase.
    private static func makeBlink(to: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = to
        a.duration = 0.5
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    /// Stop (or resume) the colon pulse and BREAK blink — called when the timer is
    /// paused/stopped. On pause both snap solid; on resume both restart in phase.
    private func setBlinkingPaused(_ paused: Bool) {
        guard paused != blinkPaused else { return }
        blinkPaused = paused
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if paused {
            colonLayer.removeAnimation(forKey: "pulse"); colonLayer.opacity = 1.0
            titleLayer.removeAnimation(forKey: "pulse"); titleLayer.opacity = 1.0
        } else {
            colonLayer.add(Self.makeBlink(to: 0.5), forKey: "pulse")
            titleLayer.add(Self.makeBlink(to: 0.5), forKey: "pulse")
        }
        CATransaction.commit()
    }

    func update(digits: String, finishText: String, flag: String, paused: Bool) {
        self.digits = digits
        self.finishText = finishText
        self.flag = flag
        self.paused = paused
        setBlinkingPaused(paused)
        needsDisplay = true
    }

    func setDigitsVisible(_ visible: Bool) {
        digitsVisible = visible
        needsDisplay = true
    }

    /// The resize corners and the control buttons are shown only while the mouse
    /// hovers the timer; `hoveredButton` highlights the button under the cursor.
    private var mouseInside = false
    private var cornerAlpha: CGFloat = 0           // resize-corner opacity while not hovering
    private var cornerHoldTimer: Timer?           // 1s hold before the fade
    private var cornerFadeTimer: Timer?           // 300ms fade-out
    private var hoveredButton: BreakButtonKind?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    private struct Layout {
        let digits: NSRect
        let label: NSRect
        let buttons: [(NSRect, BreakButtonKind)]
        let corners: [(NSRect, ResizeCorner)]
    }

    private func computeLayout() -> Layout {
        let b = bounds
        // Uniform margin around the whole content (= the BREAK→top-edge gap), kept
        // equal on all four sides: left of the flag, right of the X button, above
        // BREAK and below the end-times. The panel aspect (1.33) is chosen so the
        // height-fit digit block also spans exactly [m, width-m].
        let m = b.height * 0.096            // base margin (the space above BREAK)
        let ch = max(18, min(b.width, b.height) * 0.13)
        let bottomH = b.height * 0.17
        let bottomY = m * 0.7               // bottom margin below the end-times (−30%)

        // Digits area + the x of the digits' left edge (labels align to this).
        let hInset = m * 1.5                // left/right margins (+50%)
        let topInset = b.height * 0.26        // title band; tighter BREAK→digits gap (−30%)
        let digitsBottom = bottomY + bottomH + b.height * 0.05   // gap between digits and end-times
        let digitsArea = NSRect(x: hInset, y: digitsBottom,
                                width: b.width - 2 * hInset,
                                height: max(0, b.height - topInset - digitsBottom))
        let dscale = min(digitsArea.height / Self.cellH, digitsArea.width / Self.contentW)
        let digitsLeftX = digitsArea.midX - (Self.contentW * dscale) / 2
        let digitsRightX = digitsLeftX + Self.contentW * dscale   // right edge of the last digit

        // The bottom row — "until HH:MM 🏳" on the left, then ⏸/✕ — sits in the gap
        // between the window's bottom edge and the digits' bottom edge. The line
        // renders at its full (band-height) size and the two buttons — squares at
        // the "0" digit's height — sit RIGHT AFTER it with a small gap. If the line
        // + gap + buttons don't fit between the digits' left and right edges, the
        // whole row scales down together (text and buttons keep one height, gap tight).
        let rowH = bottomH * 0.82                       // full finish-time line height
        let rowY = (digitsArea.minY - rowH) / 2         // the row band under the digits
        let kinds: [BreakButtonKind] = [.pause, .close]
        // Natural finish line at full band height → its width and the "0" cap height.
        let natural = finishAttr(finishText, flag: flag, lineH: rowH,
                                 maxW: .greatestFiniteMagnitude, color: Self.lit)
        let capH0 = (natural.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.capHeight ?? rowH
        var side = capH0 * Self.buttonHeightK           // buttons a bit larger than the digits
        var btnGap = side * 0.3                         // between the two buttons
        var labelGap = side * 0.5                       // small gap between the text and the buttons
        var textW = natural.size().width
        let availW = max(0, digitsRightX - digitsLeftX)
        let need = textW + labelGap + side * CGFloat(kinds.count) + btnGap * CGFloat(kinds.count - 1)
        if need > availW, need > 0 {                    // scale the whole row down to fit
            let s = availW / need
            side *= s; btnGap *= s; labelGap *= s; textW *= s
        }
        // Label hugs the (possibly scaled) text width so the buttons sit just after it.
        let label = NSRect(x: digitsLeftX, y: rowY, width: textW, height: rowH)
        // Get the ACTUAL digit band (baseline → cap-top) as the line will be drawn —
        // the flag's overhang pulls the line's ink-center off the digits, so the row
        // center alone would misplace the buttons. Buttons are a bit taller than the
        // digits and centered on that band.
        let band = finishDigitBand(area: label)
        side = band.capHeight * Self.buttonHeightK
        let digitCenter = band.baselineFromBottom + band.capHeight / 2
        var buttons: [(NSRect, BreakButtonKind)] = []
        let btnStartX = digitsLeftX + textW + labelGap
        for (i, k) in kinds.enumerated() {
            let x = btnStartX + CGFloat(i) * (side + btnGap)
            buttons.append((NSRect(x: x, y: rowY + digitCenter - side / 2, width: side, height: side), k))
        }

        let corners: [(NSRect, ResizeCorner)] = [
            (NSRect(x: 0, y: 0, width: ch, height: ch), .bottomLeft),
            (NSRect(x: b.width - ch, y: 0, width: ch, height: ch), .bottomRight),
            (NSRect(x: 0, y: b.height - ch, width: ch, height: ch), .topLeft),
            (NSRect(x: b.width - ch, y: b.height - ch, width: ch, height: ch), .topRight),
        ]

        return Layout(digits: digitsArea, label: label, buttons: buttons, corners: corners)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Background is a separate layer (faded in/out); this view only paints
        // the digits, labels and buttons so they stay fully visible.
        let L = computeLayout()
        updateTitleLayer(above: L.digits)
        drawDigits(in: L.digits)
        drawLabels(in: L.label)
        // Controls appear while hovering; the resize corners stay 1s after the mouse
        // leaves then fade over 300ms, so they're easy to grab.
        if mouseInside {
            for (rect, kind) in L.buttons { drawButton(kind, rect: rect) }
        }
        let cornerA: CGFloat = mouseInside ? 1 : cornerAlpha
        if cornerA > 0 { drawResizeCorners(alpha: cornerA) }
    }

    /// Red L-brackets at the 4 corners — shown while hovering — marking (and
    /// providing a fat target for) the resize corners.
    private func drawResizeCorners(alpha: CGFloat) {
        let b = bounds
        let len = max(10, min(b.width, b.height) * 0.10)
        let i: CGFloat = 3
        let p = NSBezierPath()
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: i, y: i + len));            p.line(to: NSPoint(x: i, y: i));            p.line(to: NSPoint(x: i + len, y: i))
        p.move(to: NSPoint(x: b.width - i - len, y: i));  p.line(to: NSPoint(x: b.width - i, y: i));  p.line(to: NSPoint(x: b.width - i, y: i + len))
        p.move(to: NSPoint(x: i, y: b.height - i - len)); p.line(to: NSPoint(x: i, y: b.height - i)); p.line(to: NSPoint(x: i + len, y: b.height - i))
        p.move(to: NSPoint(x: b.width - i - len, y: b.height - i)); p.line(to: NSPoint(x: b.width - i, y: b.height - i)); p.line(to: NSPoint(x: b.width - i, y: b.height - i - len))
        // Black halo under the red bracket — the same shadow weight as the glyphs.
        let border = outlineWidth()
        NSColor.black.withAlphaComponent(alpha).setStroke()
        p.lineWidth = 4.5 + 2 * border
        p.stroke()
        Self.lit.withAlphaComponent(alpha).setStroke()
        p.lineWidth = 4.5          // 3x thicker, easy to click
        p.stroke()
    }

    private func drawDigits(in area: NSRect) {
        guard area.width > 0, area.height > 0 else { return }
        // Fit the canonical 4-digit + colon layout into the available area.
        let scale = min(area.height / Self.cellH, area.width / Self.contentW)
        let totalW = Self.contentW * scale
        let cellHpx = Self.cellH * scale
        let originX = area.midX - totalW / 2
        let originY = area.midY - cellHpx / 2     // bottom of the digit cells (y-up)

        let digitChars = digits.filter { $0 != ":" }
        for (i, ch) in digitChars.enumerated() where i < 4 {
            drawSegDigit(ch, cellX: originX + Self.dX[i] * scale, originY: originY, scale: scale)
        }
        updateColonLayer(cx: originX + Self.colonCx * scale, originY: originY, scale: scale)
    }

    // Segment membership per digit (a,b,c,d,e,f,g).
    private static let segments: [Character: Set<Character>] = [
        "0": ["a", "b", "c", "d", "e", "f"],
        "1": ["b", "c"],
        "2": ["a", "b", "g", "e", "d"],
        "3": ["a", "b", "g", "c", "d"],
        "4": ["f", "g", "b", "c"],
        "5": ["a", "f", "g", "c", "d"],
        "6": ["a", "f", "g", "c", "d", "e"],
        "7": ["a", "b", "c"],
        "8": ["a", "b", "c", "d", "e", "f", "g"],
        "9": ["a", "b", "c", "d", "f", "g"],
    ]

    // Best-effort seven-segment letters (for the timezone abbreviations).
    private static let segLetters: [Character: Set<Character>] = [
        "A": ["a", "b", "c", "e", "f", "g"], "B": ["c", "d", "e", "f", "g"],
        "C": ["a", "d", "e", "f"], "D": ["b", "c", "d", "e", "g"],
        "E": ["a", "d", "e", "f", "g"], "F": ["a", "e", "f", "g"],
        "G": ["a", "c", "d", "e", "f"], "H": ["b", "c", "e", "f", "g"],
        "I": ["b", "c"], "J": ["b", "c", "d", "e"], "L": ["d", "e", "f"],
        "N": ["c", "e", "g"], "O": ["a", "b", "c", "d", "e", "f"],
        "P": ["a", "b", "e", "f", "g"], "R": ["e", "g"],
        "S": ["a", "c", "d", "f", "g"], "T": ["d", "e", "f", "g"],
        "U": ["b", "c", "d", "e", "f"], "Y": ["b", "c", "d", "f", "g"],
    ]

    private static func segsFor(_ c: Character) -> Set<Character>? {
        segments[c] ?? segLetters[Character(c.uppercased())]
    }

    // Reverse-engineered seven-segment polygons, traced from the reference watch.
    // Canonical cell: 80 wide x 137 tall; yl is measured from the cell TOP.
    private static let cellW: CGFloat = 80, cellH: CGFloat = 137
    private static let segPolys: [Character: [(CGFloat, CGFloat)]] = [
        "a": [(15, 0), (63, 0), (68, 4), (54, 19), (24, 19), (11, 5)],
        "b": [(74, 10), (78, 14), (78, 64), (73, 68), (60, 55), (60, 24)],
        "c": [(74, 69), (78, 73), (78, 123), (73, 127), (59, 112), (59, 84)],
        "d": [(25, 118), (54, 118), (68, 132), (64, 137), (15, 137), (11, 132)],
        "e": [(5, 69), (20, 84), (20, 112), (5, 127), (1, 123), (1, 73)],
        "f": [(5, 10), (19, 24), (19, 54), (5, 68), (1, 64), (1, 14)],
        "g": [(25, 59), (54, 59), (63, 68), (54, 78), (25, 78), (16, 68)],
    ]
    // Layout (canonical units): 4 digit cells + central colon, with the
    // digit↔colon gap HALVED from the reference watch.
    private static let dX: [CGFloat] = [0, 88, 236.5, 324.5]
    private static let colonCx: CGFloat = 202.25
    private static let contentW: CGFloat = 404.5
    private static let dotR: CGFloat = 10.5
    private static let dotCy: [CGFloat] = [35.5, 101.5]   // dot centers, from cell top

    private func segPath(_ pts: [(CGFloat, CGFloat)], cellX: CGFloat, originY: CGFloat, scale: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        for (k, v) in pts.enumerated() {
            let pt = NSPoint(x: cellX + v.0 * scale, y: originY + (Self.cellH - v.1) * scale)
            if k == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        return p
    }

    private func drawSegDigit(_ c: Character, cellX: CGFloat, originY: CGFloat, scale: CGFloat) {
        // Only lit segments are drawn — unlit ones are absent (not dimmed).
        // Each lit segment gets a solid-black OUTER halo (drawn first, wide, then the
        // red fill on top), matching the flags' border weight on any backdrop.
        guard digitsVisible else { return }
        let on = Self.segments[c] ?? []
        // Union all lit segments into ONE path and fill it once under the shared
        // shadow, so the halo wraps the whole digit's silhouette evenly (filling
        // each segment separately would cast shadows between neighbours).
        let combined = NSBezierPath()
        for seg in on {
            guard let pts = Self.segPolys[seg] else { continue }
            combined.append(segPath(pts, cellX: cellX, originY: originY, scale: scale))
        }
        guard !combined.isEmpty else { return }
        combined.lineJoinStyle = .round
        withDenseShadow { Self.lit.setFill(); combined.fill() }
    }

    private func updateColonLayer(cx: CGFloat, originY: CGFloat, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // don't animate path/frame changes
        colonLayer.frame = bounds
        colonLayer.isHidden = !digitsVisible    // hide with the digits during expiry blink
        colonLayer.shadowRadius = shadowBlur()  // same soft halo weight as every element
        let r = Self.dotR * scale
        let path = CGMutablePath()
        // Spread shadowPath: the shadow is cast from dots expanded by `spread`, so
        // there's a solid (≈100%) black ring hugging each dot before the blur fades
        // — matching the stacked dense shadow the drawn elements carry.
        let spread = shadowBlur() * 0.7
        let shadowPath = CGMutablePath()
        for yl in Self.dotCy {
            let cy = originY + (Self.cellH - yl) * scale
            path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            shadowPath.addEllipse(in: CGRect(x: cx - r - spread, y: cy - r - spread,
                                             width: 2 * (r + spread), height: 2 * (r + spread)))
        }
        colonLayer.path = path
        colonLayer.shadowPath = shadowPath
        CATransaction.commit()
    }

    /// A flag emoji rendered to a plain image (no baked outline). The shared soft
    /// shadow, applied when the finish-time line is drawn, gives the flag the same
    /// even halo as the text beside it.
    private static var flagImageCache: [String: NSImage] = [:]
    private static func plainFlagImage(_ flag: String, pointSize: CGFloat) -> NSImage {
        let key = "\(flag)@\(Int(pointSize.rounded()))"
        if let cached = flagImageCache[key] { return cached }
        let font = labelFont(size: pointSize, weight: .semibold)
        let attr = NSAttributedString(string: flag, attributes: [.font: font])
        let gs = attr.size()
        guard gs.width > 1, gs.height > 1 else { return NSImage(size: NSSize(width: 1, height: 1)) }
        let img = NSImage(size: gs, flipped: false) { _ in attr.draw(at: .zero); return true }
        flagImageCache[key] = img
        return img
    }

    /// The flag emoji rendered and cropped to its OPAQUE bounds (no transparent
    /// padding), so the caller can scale it to an exact target height — the digit
    /// cap height — and get a visible flag of exactly that height rather than the
    /// emoji's padded box (which is ~15% taller than the flag it contains).
    private static var tightFlagCache: [String: NSImage] = [:]
    private static func tightFlagImage(_ flag: String) -> NSImage {
        if let cached = tightFlagCache[flag] { return cached }
        let font = labelFont(size: 160, weight: .semibold)   // big render → crisp when scaled down
        let attr = NSAttributedString(string: flag, attributes: [.font: font])
        let gs = attr.size()
        guard gs.width > 1, gs.height > 1 else { return NSImage(size: NSSize(width: 1, height: 1)) }
        let full = NSImage(size: gs, flipped: false) { _ in attr.draw(at: .zero); return true }
        guard let tiff = full.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let cg = bmp.cgImage else { return full }
        // Scan alpha (colorAt / CGImage both top-left origin) for the opaque box.
        let w = cg.width, h = cg.height
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where (bmp.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY,
              let sub = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return full }
        let out = NSImage(cgImage: sub, size: NSSize(width: sub.width, height: sub.height))
        tightFlagCache[flag] = out
        return out
    }

    /// Display font for the title & finish times — the rounded system design
    /// (distinct from the default SF, pairs cleanly with the LED digits).
    private static func labelFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: d, size: size) ?? base
        }
        return base
    }

    private static let monoCapRatio = NSFont.monospacedSystemFont(ofSize: 100, weight: .semibold).capHeight / 100
    /// Finish-time font sizing: the cap height (the height of a "0") as a fraction
    /// of the line height. The monospaced point size is `capHeight / monoCapRatio`.
    /// Was 1.02 → 0.918 → 0.826 (two −10% steps) to leave room for larger buttons.
    private static let finishCapFraction: CGFloat = 0.826
    /// ⏸/✕ button height as a multiple of the digit ("0") cap height — a bit larger
    /// than the text so the controls stay easy to hit as the finish font shrinks.
    private static let buttonHeightK: CGFloat = 1.3
    /// Flag height as a multiple of the digit cap height. A tight-cropped flag
    /// scaled to exactly `capHeight` renders visibly ~13% shorter than the digits
    /// (SF-mono digits sit a touch above the cap line); this nudges it to match.
    private static let flagHeightK: CGFloat = 1.15
    /// capHeight / pointSize for the rounded heavy title font — lets us size BREAK
    /// from a target cap height so its top & bottom gaps are exact.
    private static let titleCapRatio = labelFont(size: 100, weight: .heavy).capHeight / 100

    /// The single black-outline weight (outer halo, in view points) shared by EVERY
    /// element — the LED digits, the colon, the BREAK title, the finish-time text &
    /// arrow, the flag silhouettes, the hover buttons and the resize corners — so
    /// they all carry the same border thickness the flags originally had. Derived
    /// from the finish-time font size exactly as the flags' `pointSize * 0.07`.
    private func outlineWidth() -> CGFloat {
        let lineH = (bounds.height * 0.17) * 0.46     // finish-label line height
        let sz = 1.02 * lineH / Self.monoCapRatio     // finish-time font size
        return max(1.5, sz * 0.92 * 0.07)
    }

    /// Blur radius (in view points) of the shared element shadow. Scales with the
    /// timer size via `outlineWidth()`, so the halo keeps the same relative weight
    /// at any zoom.
    private func shadowBlur() -> CGFloat { max(2, outlineWidth() * 1.5) }

    /// The single soft drop-shadow EVERY element carries: pure black, ZERO offset
    /// (so it's exactly equal thickness on all sides) with a blur that fades toward
    /// its edge — replacing the per-element centred strokes whose visible weight
    /// differed by glyph shape and read directionally.
    private func glyphShadow() -> NSShadow {
        let sh = NSShadow()
        sh.shadowColor = NSColor.black
        sh.shadowOffset = .zero
        sh.shadowBlurRadius = shadowBlur()
        return sh
    }

    /// Stacked shadow passes. A single blurred shadow only reaches ~50% black at
    /// the element's very edge; stacking N passes compounds toward solid black
    /// hugging the element while the blur still fades out beyond — i.e. an opaque
    /// near-edge with a gradient tail.
    private static let shadowPasses = 4

    /// Draw `body` repeatedly under the shared shadow so the halo is dense
    /// (near-100% black) right next to the element and fades out beyond it.
    private func withDenseShadow(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        glyphShadow().set()
        for _ in 0..<Self.shadowPasses { body() }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLabels(in area: NSRect) {
        guard area.height > 0, area.width > 0 else { return }
        // ONE finish-time line (the picked country, default Romania). The label
        // band height IS the text line height now (the buttons match it), so use
        // it directly rather than shrinking it.
        let lineH = area.height
        let a = finishAttr(finishText, flag: flag, lineH: lineH, maxW: area.width, color: Self.lit)
        drawAttrCentered(a, x: area.minX, bottomY: area.minY, cellH: area.height)
        // The WHOLE line (flag + time) is the click target for the country dropdown
        // — a big, discoverable hit area rather than just the flag glyph.
        flagRect = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height)
    }

    /// The finish line's DIGIT band (baseline → cap-top) exactly as `drawLabels`
    /// will render it, in view points measured from the row's bottom edge, plus the
    /// rendered "0" cap height. The line is ink-centered but `draw(at:)` offsets it
    /// by the line's descent, so the digits don't sit at the row-band center — the
    /// buttons align to THIS band (and take its height) instead of the row center.
    private func finishDigitBand(area: NSRect) -> (baselineFromBottom: CGFloat, capHeight: CGFloat) {
        let attr = finishAttr(finishText, flag: flag, lineH: area.height, maxW: area.width, color: Self.lit)
        let capH = (attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.capHeight ?? area.height
        let ink = attr.boundingRect(with: NSSize(width: 1e5, height: 1e5), options: [.usesDeviceMetrics])
        let drawY = (area.height - ink.height) / 2 - ink.minY      // draw point y, relative to the row bottom
        // draw(at: p) puts the baseline at p.y + (line descent); read it from layout.
        let storage = NSTextStorage(attributedString: attr)
        let container = NSTextContainer(size: NSSize(width: 1e5, height: 1e5))
        container.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)
        var baselineAboveDraw: CGFloat = 0
        if lm.numberOfGlyphs > 0 {
            let frag = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let loc = lm.location(forGlyphAt: 0)
            baselineAboveDraw = frag.height - loc.y
        }
        return (drawY + baselineAboveDraw, capH)
    }

    /// The finish-time line "until HH:MM 🏳": the word "until" + the finish time in
    /// a MONOSPACED font, then the picked country's flag at the END. Sized to the
    /// line, clamped to width.
    private func finishAttr(_ s: String, flag: String, lineH: CGFloat, maxW: CGFloat, color: NSColor) -> NSAttributedString {
        let time = s.split(separator: " ").first.map(String.init) ?? s
        let capRatio = Self.monoCapRatio
        func build(_ sz: CGFloat) -> NSAttributedString {
            let timeFont = NSFont.monospacedSystemFont(ofSize: sz, weight: .semibold)
            // "until HH:MM" in the LED red, then a space and the picked country's
            // flag at the end. The shared shadow (set when the line is drawn) gives
            // the flag the same even halo as the text — no baked outline.
            let m = NSMutableAttributedString()
            m.append(NSAttributedString(string: "until \(time)",
                                        attributes: [.font: timeFont, .foregroundColor: color]))
            // Half a space between the time and the flag (−50% from a full space).
            let spaceAdv = (" " as NSString).size(withAttributes: [.font: timeFont]).width
            m.append(NSAttributedString(string: " ", attributes: [.font: timeFont, .kern: -spaceAdv / 2]))
            let att = NSTextAttachment()
            // The flag stands exactly as tall as the digits: a tight-cropped image
            // (no emoji padding) scaled to the cap height and sitting on the baseline,
            // so it spans [baseline, cap-top] just like the "38".
            let img = Self.tightFlagImage(flag)
            let capH = timeFont.capHeight
            let flagH = capH * Self.flagHeightK
            let aspect = img.size.height > 1 ? img.size.width / img.size.height : 1.5
            att.image = img
            // As tall as the digits, centered on the cap band so it sits level with
            // "38" and grows/shrinks with the finish font.
            att.bounds = NSRect(x: 0, y: (capH - flagH) / 2, width: flagH * aspect, height: flagH)
            m.append(NSAttributedString(attachment: att))
            return m
        }
        var size = Self.finishCapFraction * lineH / capRatio   // cap ("0") height = finishCapFraction × lineH
        var attr = build(size)
        let w = attr.size().width
        if w > maxW { size *= maxW / w; attr = build(size) }
        return attr
    }

    /// Draw an attributed line left-aligned at `x`, centering its ink in the slot.
    private func drawAttrCentered(_ attr: NSAttributedString, x: CGFloat, bottomY: CGFloat, cellH: CGFloat) {
        let ink = attr.boundingRect(with: NSSize(width: 1e5, height: 1e5), options: [.usesDeviceMetrics])
        drawOutlinedAttr(attr, at: NSPoint(x: x, y: bottomY + (cellH - ink.height) / 2 - ink.minY))
    }

    /// Attributed text (incl. the flag attachment) drawn under the shared soft
    /// shadow, so the whole finish-time line carries one even halo.
    private func drawOutlinedAttr(_ attr: NSAttributedString, at p: NSPoint) {
        withDenseShadow { attr.draw(at: p) }
    }

    /// Render the blinking "BREAK" title onto its own layer, centered (by ink) in
    /// the top band above the digits. The layer's opacity blinks in sync with the
    /// colon; here we only refresh its image/position on layout changes.
    private func updateTitleLayer(above digits: NSRect) {
        let b = bounds
        let bandBottom = digits.maxY
        let bandH = b.height - bandBottom
        guard bandH > 4 else { titleLayer.isHidden = true; return }
        titleLayer.isHidden = !digitsVisible
        // Derive the BREAK size so its cap-top sits `m` below the panel's top edge
        // and its cap-bottom sits `vgap` above the digits — making the BREAK→digits
        // gap equal to the digits→end-times gap (both `vgap`).
        let m = b.height * 0.096
        let vgap = b.height * 0.05
        let targetCap = max(4, bandH - m - vgap)
        var fontSize = targetCap / Self.titleCapRatio
        var font = Self.labelFont(size: fontSize, weight: .heavy)
        // A longer title (e.g. "UNTIL BREAK") would overflow the panel at the
        // height-derived size; shrink it so it also fits the available width.
        let availW = max(1, b.width - 2 * m)
        let naturalW = NSAttributedString(string: titleText, attributes: [.font: font]).size().width
        if naturalW > availW {
            fontSize *= availW / naturalW
            font = Self.labelFont(size: fontSize, weight: .heavy)
        }
        let pad: CGFloat = max(2, font.pointSize * 0.14)   // headroom for the shadow
        let str = NSAttributedString(string: titleText, attributes: [.font: font])
        // Size the image from FONT metrics (ascender..descender) so the glyphs can
        // never overflow it — drawing at (pad, pad) puts the line box inside, and
        // the visible caps sit a known distance up from the bottom.
        let imgW = ceil(str.size().width + pad * 2)
        let imgH = ceil(font.ascender - font.descender + pad * 2)   // descender is negative
        guard imgW > 1, imgH > 1 else { titleLayer.isHidden = true; return }
        let title = titleText
        let img = NSImage(size: NSSize(width: imgW, height: imgH), flipped: false) { [weak self] _ in
            self?.drawOutlinedText(title, at: NSPoint(x: pad, y: pad), font: font, fill: Self.lit)
            return true
        }
        // Caps occupy [baseline, baseline+capHeight] within the image; anchor that
        // cap-top a fixed margin below the panel edge so it's never clipped.
        let capsTopInImg = (pad - font.descender) + font.capHeight   // baseline + capHeight
        CATransaction.begin(); CATransaction.setDisableActions(true)
        titleLayer.contents = img
        titleLayer.contentsScale = window?.backingScaleFactor ?? 2
        titleLayer.frame = NSRect(x: b.midX - imgW / 2,
                                  y: (b.height - m) - capsTopInImg,   // cap-top sits `m` below the top edge
                                  width: imgW, height: imgH)
        CATransaction.commit()
    }

    /// Text with the shared soft drop-shadow under the fill (no stroke), so BREAK
    /// carries the same even halo as every other element.
    private func drawOutlinedText(_ s: String, at p: NSPoint, font: NSFont, fill: NSColor, kern: CGFloat = 0) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: fill, .kern: kern,
        ])
        withDenseShadow { attr.draw(at: p) }
    }

    private func drawButton(_ kind: BreakButtonKind, rect r: NSRect) {
        let pressed = pressedButton == kind
        let hovered = hoveredButton == kind
        let radius = r.height * 0.25
        // Solid-black halo around the whole button — the same shadow weight the
        // glyphs carry — so the buttons read with a border on any backdrop.
        let border = outlineWidth()
        let halo = NSBezierPath(roundedRect: r.insetBy(dx: -border, dy: -border),
                                xRadius: radius + border, yRadius: radius + border)
        NSColor.black.setFill(); halo.fill()
        let bg = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        // Opaque black base so the button reads solidly even when the backdrop
        // is transparent (while the user is active); red tint deepens on hover/press.
        NSColor.black.setFill()
        bg.fill()
        let bgAlpha: CGFloat = pressed ? 0.45 : (hovered ? 0.30 : 0.18)
        Self.lit.withAlphaComponent(bgAlpha).setFill()
        bg.fill()
        Self.lit.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let inset = r.insetBy(dx: r.width * 0.28, dy: r.height * 0.28)
        switch kind {
        case .close:
            Self.lit.setStroke()
            let p = NSBezierPath()
            p.lineWidth = max(1.5, r.height * 0.08)
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: inset.minX, y: inset.minY)); p.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            p.move(to: NSPoint(x: inset.minX, y: inset.maxY)); p.line(to: NSPoint(x: inset.maxX, y: inset.minY))
            p.stroke()
        case .pause:
            Self.lit.setFill()
            if paused {
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: inset.minX, y: inset.minY))
                tri.line(to: NSPoint(x: inset.minX, y: inset.maxY))
                tri.line(to: NSPoint(x: inset.maxX, y: inset.midY))
                tri.close(); tri.fill()
            } else {
                let barW = inset.width * 0.34
                NSBezierPath(rect: NSRect(x: inset.minX, y: inset.minY, width: barW, height: inset.height)).fill()
                NSBezierPath(rect: NSRect(x: inset.maxX - barW, y: inset.minY, width: barW, height: inset.height)).fill()
            }
        }
    }

    // MARK: Mouse

    private func cornerHit(_ p: NSPoint, _ L: Layout) -> ResizeCorner? {
        for (rect, corner) in L.corners where rect.contains(p) { return corner }
        return nil
    }

    private func buttonHit(_ p: NSPoint, _ L: Layout) -> BreakButtonKind? {
        for (rect, kind) in L.buttons where rect.contains(p) { return kind }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let L = computeLayout()
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window?.frame ?? .zero
        if let corner = cornerHit(p, L) {
            dragMode = .resize(corner)
            Self.cursor(forCorner: corner).set()
        } else if let kind = buttonHit(p, L) {
            dragMode = .button(kind)
            pressedButton = kind
            needsDisplay = true
        } else if flagRect.contains(p) {
            dragMode = .none
            showCountryPicker()
            return
        } else {
            dragMode = .move
            Self.moveCursor.set()   // plain arrow — no grab hand
        }
        // While held, capture the wheel globally so minute-adjust keeps working
        // even if the cursor leaves the view during a drag.
        startScrollMonitor()
    }

    override func mouseDragged(with event: NSEvent) {
        switch dragMode {
        case .move:
            Self.moveCursor.set()   // plain arrow — no grab hand
            let m = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: dragStartFrame.origin.x + (m.x - dragStartMouse.x),
                                           y: dragStartFrame.origin.y + (m.y - dragStartMouse.y)))
        case .resize(let corner):
            Self.cursor(forCorner: corner).set()
            performResize(corner)
        case .button, .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .button(let kind) = dragMode {
            if buttonHit(p, computeLayout()) == kind { fire(kind) }
        }
        dragMode = .none
        pressedButton = nil
        needsDisplay = true
        stopScrollMonitor()
        // Restore the resting cursor for the release position (resize at a corner,
        // pointer over a button, plain arrow over the body).
        let L = computeLayout()
        if let corner = cornerHit(p, L) { Self.cursor(forCorner: corner).set() }
        else if buttonHit(p, L) != nil { NSCursor.pointingHand.set() }
        else { Self.moveCursor.set() }
    }

    // While the timer is held, capture the wheel with a CGEventTap so minute-
    // adjust keeps working wherever the cursor goes during a drag AND the scroll
    // is consumed (it never leaks to the app underneath). A tap (unlike an
    // NSEvent global monitor) can swallow the event.
    private func startScrollMonitor() {
        stopScrollMonitor()
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let view = Unmanaged<BreakTimerView>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = view.scrollTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .scrollWheel {
                view.handleTapScroll(event)
                return nil   // consume — don't let it reach the app below
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: refcon) else { return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        scrollTap = tap
        scrollTapSource = src
    }

    private func stopScrollMonitor() {
        if let tap = scrollTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let src = scrollTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        scrollTap = nil
        scrollTapSource = nil
        scrollAccum = 0
    }

    func handleTapScroll(_ event: CGEvent) {
        // Scroll UP adds time, scroll DOWN subtracts.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            let dy = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            scrollAccum += dy
            while scrollAccum >= 20 { onAdd?(-1); scrollAccum -= 20 }
            while scrollAccum <= -20 { onAdd?(1); scrollAccum += 20 }
        } else {
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)   // line units
            if dy != 0 { onAdd?(dy > 0 ? -1 : 1) }
        }
    }

    deinit { stopScrollMonitor() }

    private func fire(_ kind: BreakButtonKind) {
        switch kind {
        case .close: onClose?()
        case .pause: onTogglePause?()
        }
    }

    /// Open the searchable country dropdown anchored under the 2nd-line flag.
    /// Typing filters by name (contains); picking fires `onSelectCountry`.
    private func showCountryPicker() {
        let flagInWindow = convert(flagRect, to: nil)                       // view → window
        let flagOnScreen = window?.convertToScreen(flagInWindow) ?? flagInWindow
        countryPicker.present(below: flagOnScreen, selectedTZ: selectedCountryTZ) { [weak self] c in
            self?.onSelectCountry?(c)
        }
    }

    /// Headless test entry point (`/test/break/picker`): open the picker without a
    /// click and optionally pre-fill the filter query.
    func openPickerForTest(query: String?) {
        showCountryPicker()
        if let q = query, !q.isEmpty { countryPicker.applyQuery(q) }
    }

    private func performResize(_ corner: ResizeCorner) {
        guard let window else { return }
        let aspect = dragStartFrame.height > 0 ? dragStartFrame.width / dragStartFrame.height : BreakTimerController.aspect
        let m = NSEvent.mouseLocation
        let anchor: NSPoint
        let leftGrab: Bool
        let bottomGrab: Bool
        switch corner {
        case .bottomLeft:  anchor = NSPoint(x: dragStartFrame.maxX, y: dragStartFrame.maxY); leftGrab = true;  bottomGrab = true
        case .bottomRight: anchor = NSPoint(x: dragStartFrame.minX, y: dragStartFrame.maxY); leftGrab = false; bottomGrab = true
        case .topLeft:     anchor = NSPoint(x: dragStartFrame.maxX, y: dragStartFrame.minY); leftGrab = true;  bottomGrab = false
        case .topRight:    anchor = NSPoint(x: dragStartFrame.minX, y: dragStartFrame.minY); leftGrab = false; bottomGrab = false
        }
        let wantW = abs(m.x - anchor.x)
        let wantH = abs(m.y - anchor.y)
        var newW = max(wantW, wantH * aspect)
        newW = max(BreakTimerController.minWidth, newW)
        let newH = newW / aspect
        let originX = leftGrab ? anchor.x - newW : anchor.x
        let originY = bottomGrab ? anchor.y - newH : anchor.y
        window.setFrame(NSRect(x: originX, y: originY, width: newW, height: newH), display: true)
    }

    // MARK: Wheel — drag adjusts minutes, hover zooms

    // Hovering (no button held) + wheel zooms the watch *around the cursor*: the
    // point under the pointer keeps its exact relative position, so whatever you
    // point at stays put while the size changes.
    //
    // While the button is HELD (a move/resize/button drag), the wheel adjusts the
    // time value instead. When the global scroll tap is active it already
    // consumes the wheel for minute-adjust before this fires; this branch makes
    // drag+wheel adjust the value even when that tap couldn't be installed (e.g.
    // Accessibility not granted), so the two behaviours never get confused.
    override func scrollWheel(with event: NSEvent) {
        if case .none = dragMode {
            // Hover → zoom. Up → zoom in, down → zoom out (up reads as a negative
            // delta). Exponential so it feels uniform.
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 16
            guard dy != 0 else { return }
            let factor = CGFloat(exp(Double(-dy) * 0.0035))
            zoomWindow(by: factor, around: NSEvent.mouseLocation)
        } else {
            // Dragging → adjust minutes (up adds, down subtracts; up is a negative
            // delta). Accumulate precise deltas so a trackpad isn't hyper-sensitive.
            if event.hasPreciseScrollingDeltas {
                scrollAccum += event.scrollingDeltaY
                while scrollAccum <= -20 { onAdd?(1);  scrollAccum += 20 }
                while scrollAccum >=  20 { onAdd?(-1); scrollAccum -= 20 }
            } else {
                let dy = event.deltaY
                if dy != 0 { onAdd?(dy < 0 ? 1 : -1) }
            }
        }
    }

    private func zoomWindow(by factor: CGFloat, around cursor: NSPoint) {
        guard let window else { return }
        let f = window.frame
        guard f.width > 0, f.height > 0 else { return }
        let aspect = f.width / f.height
        let maxW = ((window.screen ?? NSScreen.main)?.frame.width ?? f.width * 4) * 0.98
        let newW = min(max(BreakTimerController.minWidth, f.width * factor), maxW)
        let newH = newW / aspect
        // Pin the cursor to its current relative position inside the window.
        let rx = (cursor.x - f.minX) / f.width
        let ry = (cursor.y - f.minY) / f.height
        let originX = cursor.x - rx * newW
        let originY = cursor.y - ry * newH
        window.setFrame(NSRect(x: originX, y: originY, width: newW, height: newH), display: true)
    }

    // MARK: Cursor

    // Standard OS cursors: the system diagonal resize cursors at the corners
    // (behind verified private selectors). The body uses the plain arrow — never a
    // grab/hand cursor, which used to linger stuck on screen after the timer closed
    // or the pointer moved away.
    private static let moveCursor = NSCursor.arrow
    private static let nwseCursor = privateCursor("_windowResizeNorthWestSouthEastCursor", fallback: .crosshair)
    private static let neswCursor = privateCursor("_windowResizeNorthEastSouthWestCursor", fallback: .crosshair)

    private static func privateCursor(_ name: String, fallback: NSCursor) -> NSCursor {
        if let cursor = NSCursor.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return fallback
    }

    private static func cursor(forCorner corner: ResizeCorner) -> NSCursor {
        switch corner {
        case .bottomLeft, .topRight: return neswCursor
        case .bottomRight, .topLeft: return nwseCursor
        }
    }

    // Cursor rectangles are AppKit's standard mechanism for per-region hover
    // cursors and work even when the window is in the background (the way a
    // background window still shows a resize cursor at its edges).
    override func resetCursorRects() {
        let L = computeLayout()
        addCursorRect(bounds, cursor: Self.moveCursor)                       // body → move
        for (rect, _) in L.buttons { addCursorRect(rect, cursor: NSCursor.pointingHand) }
        for (rect, corner) in L.corners { addCursorRect(rect, cursor: Self.cursor(forCorner: corner)) }
    }

    // Tracking area: mouseEntered claims cursor management; enter/exit/moved
    // drive the hover state for the corners and buttons.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)   // cursor rects depend on layout
    }

    override func mouseEntered(with event: NSEvent) {
        // Become key (without activating the app) so our cursor rects are honored.
        window?.makeKey()
        window?.invalidateCursorRects(for: self)
        mouseInside = true
        cornerHoldTimer?.invalidate(); cornerHoldTimer = nil
        cornerFadeTimer?.invalidate(); cornerFadeTimer = nil
        cornerAlpha = 1
        needsDisplay = true
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        hoveredButton = nil
        cornerAlpha = 1
        needsDisplay = true
        // updateHover sets cursors imperatively (open-hand on the body, pointer on
        // buttons), which bypasses AppKit's cursor-rect restoration. Without this,
        // leaving the timer after a hover/move leaves the open-hand cursor stuck.
        // While a drag is in progress keep the drag cursor; mouseUp restores it.
        if case .none = dragMode { NSCursor.arrow.set() }
        // Stay fully visible for 1s, then fade out over 300ms.
        cornerHoldTimer?.invalidate(); cornerFadeTimer?.invalidate()
        let hold = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in self?.startCornerFade() }
        RunLoop.main.add(hold, forMode: .common)
        cornerHoldTimer = hold
    }

    private func startCornerFade() {
        cornerFadeTimer?.invalidate()
        let duration = 0.3, step = 1.0 / 60.0
        var elapsed = 0.0
        let t = Timer(timeInterval: step, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            elapsed += step
            self.cornerAlpha = max(0, 1 - CGFloat(elapsed / duration))
            self.needsDisplay = true
            if elapsed >= duration { tm.invalidate(); self.cornerFadeTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        cornerFadeTimer = t
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(event)
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let L = computeLayout()
        let h = buttonHit(p, L)
        if h != hoveredButton { hoveredButton = h; needsDisplay = true }
        // Set the cursor for the hovered region (resize on corners, pointer on
        // buttons, open-hand on the body) — works because we became key on enter.
        if let corner = cornerHit(p, L) {
            Self.cursor(forCorner: corner).set()
        } else if h != nil {
            NSCursor.pointingHand.set()
        } else {
            Self.moveCursor.set()
        }
    }
}
