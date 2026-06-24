import AppKit
import QuartzCore

/// Break countdown "watch" overlay: a draggable, resizable, mouse-interactive
/// panel showing a big red seven-segment MM:SS countdown over a frosted-glass
/// (blurred) 60%-opaque black background, the finish time in two timezones, and
/// small controls (+1 / +3 / +5 / pause / close). Hovering shows resize cursors
/// at the corners and a 4-way move cursor on the body. On expiry it gongs twice,
/// blinks twice, and fades out. Unlike OverlayPanel, this panel accepts mouse events.

// MARK: - Controller

final class BreakTimerController {
    static let aspect: CGFloat = 1.85         // width / height; locked on resize
    static let minWidth: CGFloat = 180

    private var panel: BreakTimerPanel?
    private var view: BreakTimerView?

    private var remaining = 0                  // seconds
    private var paused = false
    private var freezeNow: Date?              // wall-clock frozen while paused
    private var timer: Timer?
    private var blinkTimer: Timer?            // drives the expiry blink
    private var activityTimer: Timer?         // toggles the background while the user works
    private var bgView: NSView?              // opaque backdrop, faded in/out
    private var bgOpaque = true              // current backdrop state
    private var epoch = 0                      // invalidates in-flight expiry blocks

    private let cetZone = TimeZone(identifier: "Europe/Paris") ?? .current

    /// (Re)start the countdown at `minutes`. Reuses the existing window in place
    /// (keeping its position & size); a fresh window opens top-right at 25% width.
    func start(minutes: Int) {
        epoch += 1
        blinkTimer?.invalidate(); blinkTimer = nil
        remaining = max(0, minutes) * 60
        paused = false
        freezeNow = nil

        let view = ensureWindow()
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
        SoundManager.shared.stopOverlapping("50_gong.mp3")  // interrupt a gong in progress
        timer?.invalidate(); timer = nil
        blinkTimer?.invalidate(); blinkTimer = nil
        activityTimer?.invalidate(); activityTimer = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        bgView = nil
        clearPersisted()
    }

    // MARK: - Persistence (survive an app redeploy mid-break)

    private static let kFinishAt = "BreakTimer.finishAt"
    private static let kPausedRemaining = "BreakTimer.pausedRemaining"

    private func persist() {
        let d = UserDefaults.standard
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
        let v = ensureWindow()
        v.setDigitsVisible(true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        if !isPaused { startTicking() }
        startActivityMonitor()
        refresh()
    }

    /// Chaotic 2D shake for the expiry: violent at each gong strike, then decaying
    /// fully to still as that strike's sound fades out (no residual jitter). Not
    /// just on X — the watch wobbles all over the place.
    private func startExpiryShake(totalDuration: Double, strikeAt: [Double]) {
        guard let layer = panel?.contentView?.layer else { return }
        let fps = 60.0
        let n = max(2, Int(totalDuration * fps))
        let peak: CGFloat = 36                         // same peak amplitude as before
        let k = 2.4                                    // decay rate ~ the gong's loud fade
        func env(_ t: Double) -> Double {
            var bump = 0.0
            for s in strikeAt where t >= s { bump += exp(-k * (t - s)) }
            return Double(peak) * min(1.0, bump)       // decays to 0 → still as the gong fades
        }
        var xs = [NSNumber](), ys = [NSNumber]()
        for i in 0..<n {
            let t = Double(i) / fps
            let e = env(t)
            // incommensurate frequencies on X and Y → chaotic, non-axis-aligned wobble
            let dx = e * (0.7 * sin(t * 2 * .pi * 7.3) + 0.3 * sin(t * 2 * .pi * 13.1 + 0.7))
            let dy = e * (0.7 * sin(t * 2 * .pi * 9.7 + 1.1) + 0.3 * sin(t * 2 * .pi * 5.3 + 2.0))
            xs.append(NSNumber(value: dx)); ys.append(NSNumber(value: dy))
        }
        let ax = CAKeyframeAnimation(keyPath: "transform.translation.x")
        ax.values = xs; ax.duration = totalDuration; ax.isAdditive = true; ax.calculationMode = .cubic
        let ay = CAKeyframeAnimation(keyPath: "transform.translation.y")
        ay.values = ys; ay.duration = totalDuration; ay.isAdditive = true; ay.calculationMode = .cubic
        layer.add(ax, forKey: "shakeX")
        layer.add(ay, forKey: "shakeY")
    }

    // MARK: - Activity-driven backdrop

    /// While the user is active (mouse/keyboard within the last 5s) the opaque
    /// backdrop fades fully away — only the outlined digits remain. After 5s
    /// idle it fades back to fully opaque. One smooth fade per transition, so
    /// it never flickers.
    private func startActivityMonitor() {
        activityTimer?.invalidate()
        // Start with NO backdrop — the timer just appeared because the user acted,
        // so the mouse is active; the backdrop fades in only after 30s idle.
        bgOpaque = false
        bgView?.alphaValue = 0
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.setBackgroundOpaque(Self.systemIdleSeconds() >= 30.0)
        }
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
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
        let frame = Self.defaultFrame()
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
        }
    }

    private func refresh() {
        guard let view else { return }
        let basis = (paused ? freezeNow : nil) ?? Date()
        view.update(
            digits: BreakTimerModel.format(remaining: remaining),
            finishLocal: BreakTimerModel.finishLabel(now: basis, remaining: remaining, timeZone: .current),
            finishCET: BreakTimerModel.finishLabel(now: basis, remaining: remaining, timeZone: cetZone),
            paused: paused
        )
    }

    /// At zero: two gong strikes, each shaking the watch left↔right to simulate
    /// the gong's vibration, then close.
    private func beginExpiry() {
        timer?.invalidate(); timer = nil
        clearPersisted()
        let myEpoch = epoch
        // Play the FULL gong (exact same mp3 as tablet effect #50 — not a clip),
        // then the second strike after the first finishes.
        let gong = SoundManager.shared.soundDuration("50_gong.mp3") ?? 8.6

        SoundManager.shared.playOverlapping("50_gong.mp3")   // strike 1 (full)
        // One continuous chaotic shake spanning both strikes; peaks at t=0 and t=gong.
        startExpiryShake(totalDuration: 2 * gong, strikeAt: [0, gong])
        DispatchQueue.main.asyncAfter(deadline: .now() + gong) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            SoundManager.shared.playOverlapping("50_gong.mp3")   // strike 2 (full)
        }
        // Stay on screen until the second gong has fully played out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * gong) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            self.close()
        }
    }

    private static func defaultFrame() -> NSRect {
        // "Main screen" = the primary display (menu-bar screen, origin .zero) —
        // NSScreen.main is the *focused* screen, which may be an external monitor.
        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main ?? NSScreen.screens.first
        let f = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Default placement/size measured from the reference: ~29% of screen
        // width, top-right with a 6.4% right gap and 15% top gap.
        let w = f.width * 0.29
        let h = w / aspect
        let x = f.maxX - w - f.width * 0.064
        let y = f.maxY - f.height * 0.15 - h
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

enum BreakButtonKind { case close, pause, add1, add3, add5 }
private enum ResizeCorner { case bottomLeft, bottomRight, topLeft, topRight }
private enum DragMode { case none, move, resize(ResizeCorner), button(BreakButtonKind) }

// MARK: - View

final class BreakTimerView: NSView {
    var onClose: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onAdd: ((Int) -> Void)?

    private var digits = "00:00"
    private var finishLocal = ""
    private var finishCET = ""
    private var paused = false
    private var digitsVisible = true

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
        colonLayer.strokeColor = NSColor.black.cgColor
        colonLayer.lineWidth = 2
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

    func update(digits: String, finishLocal: String, finishCET: String, paused: Bool) {
        self.digits = digits
        self.finishLocal = finishLocal
        self.finishCET = finishCET
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
        let pad = b.height * 0.08
        let ch = max(18, min(b.width, b.height) * 0.13)
        let bottomH = b.height * 0.17
        let bottomY = pad * 0.9            // bottom margin (+50%)

        // Digits area + the x of the digits' left edge (labels align to this).
        // Content margins increased 50% on all four edges.
        let hInset = b.width * 0.06
        let topInset = b.height * 0.20        // room for the (large) BREAK title
        let digitsBottom = bottomY + bottomH + b.height * 0.09   // 3x bigger gap to the countdown
        let digitsArea = NSRect(x: hInset, y: digitsBottom,
                                width: b.width - 2 * hInset,
                                height: max(0, b.height - topInset - digitsBottom))
        let dscale = min(digitsArea.height / Self.cellH, digitsArea.width / Self.contentW)
        let digitsLeftX = digitsArea.midX - (Self.contentW * dscale) / 2
        let digitsRightX = digitsLeftX + Self.contentW * dscale   // right edge of the last digit

        // Finish-time labels: left-aligned to the digits' left margin. Wide
        // enough that the digit-height tz labels don't starve the line width.
        let labelRight = ch + b.width * 0.47
        let label = NSRect(x: digitsLeftX, y: bottomY,
                           width: max(0, labelRight - digitsLeftX), height: bottomH)

        // Buttons end exactly at the digits' right edge.
        let btnLeft = label.maxX
        let btnRight = digitsRightX
        let kinds: [BreakButtonKind] = [.add1, .add3, .add5, .pause, .close]
        var buttons: [(NSRect, BreakButtonKind)] = []
        let areaW = max(0, btnRight - btnLeft)
        let gap = areaW * 0.03
        let bw = (areaW - gap * CGFloat(kinds.count - 1)) / CGFloat(kinds.count)
        let bh = min(bottomH, bw)
        for (i, k) in kinds.enumerated() {
            let x = btnLeft + CGFloat(i) * (bw + gap)
            buttons.append((NSRect(x: x, y: bottomY + (bottomH - bh) / 2, width: bw, height: bh), k))
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
        let border = outlineWidth()
        for seg in on {
            guard let pts = Self.segPolys[seg] else { continue }
            let path = segPath(pts, cellX: cellX, originY: originY, scale: scale)
            path.lineJoinStyle = .round
            NSColor.black.setStroke(); path.lineWidth = 2 * border; path.stroke()
            Self.lit.setFill(); path.fill()
        }
    }

    private func updateColonLayer(cx: CGFloat, originY: CGFloat, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // don't animate path/frame changes
        colonLayer.frame = bounds
        colonLayer.isHidden = !digitsVisible    // hide with the digits during expiry blink
        colonLayer.lineWidth = 2 * outlineWidth()   // same black halo weight as the digits
        let r = Self.dotR * scale
        let path = CGMutablePath()
        for yl in Self.dotCy {
            let cy = originY + (Self.cellH - yl) * scale
            path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
        colonLayer.path = path
        CATransaction.commit()
    }

    /// A flag emoji rendered to an image with a baked black outline (8-way
    /// silhouette), so color-emoji flags get the same black border as the text.
    /// `border` is the halo thickness in points (the shared `outlineWidth()`),
    /// so flags carry the exact same border weight as every other glyph.
    private static var flagImageCache: [String: NSImage] = [:]
    private static func outlinedFlagImage(_ flag: String, pointSize: CGFloat, border: CGFloat) -> NSImage {
        let b = max(0.5, border)
        let key = "\(flag)@\(Int(pointSize.rounded()))b\(Int((b * 4).rounded()))"
        if let cached = flagImageCache[key] { return cached }
        let font = labelFont(size: pointSize, weight: .semibold)
        let attr = NSAttributedString(string: flag, attributes: [.font: font])
        let gs = attr.size()
        guard gs.width > 1, gs.height > 1 else { return NSImage(size: NSSize(width: 1, height: 1)) }
        let glyph = NSImage(size: gs, flipped: false) { _ in attr.draw(at: .zero); return true }
        let silhouette = NSImage(size: gs, flipped: false) { rect in
            glyph.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.black.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let out = NSSize(width: ceil(gs.width + 2 * b), height: ceil(gs.height + 2 * b))
        let img = NSImage(size: out, flipped: false) { _ in
            let offs: [(CGFloat, CGFloat)] = [(-1,0),(1,0),(0,-1),(0,1),(-0.7,-0.7),(0.7,-0.7),(-0.7,0.7),(0.7,0.7)]
            for (dx, dy) in offs {
                silhouette.draw(at: NSPoint(x: b + dx * b, y: b + dy * b), from: .zero,
                                operation: .sourceOver, fraction: 1)
            }
            glyph.draw(at: NSPoint(x: b, y: b), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        flagImageCache[key] = img
        return img
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

    private func drawLabels(in area: NSRect) {
        guard area.height > 0, area.width > 0 else { return }
        let lineH = area.height * 0.46
        let topBottom = area.minY + area.height - lineH      // top line slot bottom
        let gap: CGFloat = 5                                  // extra space between the two lines
        // Both lines at the SAME opacity; no background — just the black outline.
        let (a1, pct1) = finishAttr(finishLocal, flag: "🇷🇴", lineH: lineH, maxW: area.width, color: Self.lit)
        let (a2, pct2) = finishAttr(finishCET, flag: "🇪🇺", lineH: lineH, maxW: area.width, color: Self.lit)
        drawAttrCentered(a1, x: area.minX, bottomY: topBottom + gap / 2, cellH: lineH, strokePct: pct1)
        drawAttrCentered(a2, x: area.minX, bottomY: area.minY - gap / 2, cellH: lineH, strokePct: pct2)
    }

    /// A finish-time line "🏳 → HH:MM": the region flag FIRST (RO local, EU CET),
    /// then the arrow and time in a MONOSPACED font so the two lines' columns align.
    /// Sized to the line, clamped to width.
    private func finishAttr(_ s: String, flag: String, lineH: CGFloat, maxW: CGFloat, color: NSColor) -> (NSAttributedString, CGFloat) {
        let time = s.split(separator: " ").first.map(String.init) ?? s
        let capRatio = Self.monoCapRatio
        let border = outlineWidth()                    // shared black-outline weight
        func build(_ sz: CGFloat) -> NSAttributedString {
            let timeFont = NSFont.monospacedSystemFont(ofSize: sz, weight: .semibold)
            // Flag as an image with a baked black outline (emoji ignore text stroke).
            let att = NSTextAttachment()
            let img = Self.outlinedFlagImage(flag, pointSize: sz * 0.92, border: border)
            att.image = img
            att.bounds = NSRect(x: 0, y: (timeFont.capHeight - img.size.height) / 2,
                                width: img.size.width, height: img.size.height)
            let m = NSMutableAttributedString(attributedString: NSAttributedString(attachment: att))
            // Center the arrow in the whitespace between the flag and the first digit:
            // equal whitespace on both sides (accounting for the flag image's border).
            let spaceAdv = (" " as NSString).size(withAttributes: [.font: timeFont]).width
            let flagBorder = border                          // matches outlinedFlagImage's border
            let leftAdv = max(0, (spaceAdv - flagBorder) / 2)
            let rightAdv = (spaceAdv + flagBorder) / 2
            m.append(NSAttributedString(string: " ", attributes: [.font: timeFont, .kern: leftAdv - spaceAdv]))
            m.append(NSAttributedString(string: "→", attributes: [.font: timeFont, .foregroundColor: color]))
            m.append(NSAttributedString(string: " ", attributes: [.font: timeFont, .kern: rightAdv - spaceAdv, .foregroundColor: color]))
            m.append(NSAttributedString(string: time, attributes: [.font: timeFont, .foregroundColor: color]))
            return m
        }
        var size = 1.02 * lineH / capRatio             // end-time font (+20%)
        var attr = build(size)
        let w = attr.size().width
        if w > maxW { size *= maxW / w; attr = build(size) }
        // Centered text stroke whose outer half equals `border` → same halo as the flag.
        let strokePct = 200 * border / size
        return (attr, strokePct)
    }

    /// Draw an attributed line left-aligned at `x`, centering its ink in the slot.
    private func drawAttrCentered(_ attr: NSAttributedString, x: CGFloat, bottomY: CGFloat, cellH: CGFloat, strokePct: CGFloat) {
        let ink = attr.boundingRect(with: NSSize(width: 1e5, height: 1e5), options: [.usesDeviceMetrics])
        drawOutlinedAttr(attr, at: NSPoint(x: x, y: bottomY + (cellH - ink.height) / 2 - ink.minY), strokePct: strokePct)
    }

    /// Attributed text with a solid-black OUTER border (stroke pass beneath the fill),
    /// `strokePct` sized so the visible outer halo matches the flags' border weight.
    /// Flags carry their own baked outline, so only the text needs the stroke.
    private func drawOutlinedAttr(_ attr: NSAttributedString, at p: NSPoint, strokePct: CGFloat) {
        let stroke = NSMutableAttributedString(attributedString: attr)
        stroke.addAttributes([.foregroundColor: NSColor.clear,
                              .strokeColor: NSColor.black,
                              .strokeWidth: strokePct],
                             range: NSRange(location: 0, length: stroke.length))
        stroke.draw(at: p)
        attr.draw(at: p)
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
        let font = Self.labelFont(size: bandH * 0.96, weight: .heavy)   // +20%
        let pad: CGFloat = max(2, font.pointSize * 0.14)   // headroom for the outline stroke
        let str = NSAttributedString(string: "BREAK", attributes: [.font: font])
        // Size the image from FONT metrics (ascender..descender) so the glyphs can
        // never overflow it — drawing at (pad, pad) puts the line box inside, and
        // the visible caps sit a known distance up from the bottom.
        let imgW = ceil(str.size().width + pad * 2)
        let imgH = ceil(font.ascender - font.descender + pad * 2)   // descender is negative
        guard imgW > 1, imgH > 1 else { titleLayer.isHidden = true; return }
        let img = NSImage(size: NSSize(width: imgW, height: imgH), flipped: false) { [weak self] _ in
            self?.drawOutlinedText("BREAK", at: NSPoint(x: pad, y: pad), font: font, fill: Self.lit)
            return true
        }
        // Caps occupy [baseline, baseline+capHeight] within the image; anchor that
        // cap-top a fixed margin below the panel edge so it's never clipped.
        let capsTopInImg = (pad - font.descender) + font.capHeight   // baseline + capHeight
        let topGap = bandH * 0.16
        CATransaction.begin(); CATransaction.setDisableActions(true)
        titleLayer.contents = img
        titleLayer.contentsScale = window?.backingScaleFactor ?? 2
        titleLayer.frame = NSRect(x: b.midX - imgW / 2,
                                  y: (b.height - topGap) - capsTopInImg,
                                  width: imgW, height: imgH)
        CATransaction.commit()
    }

    /// Text with a solid-black OUTER border (stroke under the fill, so the fill shows),
    /// at the shared `outlineWidth()` weight so BREAK matches every other glyph.
    private func drawOutlinedText(_ s: String, at p: NSPoint, font: NSFont, fill: NSColor, kern: CGFloat = 0) {
        let pct = 200 * outlineWidth() / font.pointSize   // centered stroke → half sits outside
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: NSColor.clear, .kern: kern,
            .strokeColor: NSColor.black, .strokeWidth: pct,
        ]).draw(at: p)
        NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: fill, .kern: kern,
        ]).draw(at: p)
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
        case .add1, .add3, .add5:
            let text = kind == .add1 ? "+1" : (kind == .add3 ? "+3" : "+5")
            // Size the text to fill the button (≈86% of it).
            let base: CGFloat = 100
            let probe = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: base, weight: .regular)])
            let psz = probe.size()
            let scale = min(r.width * 0.86 / psz.width, r.height * 0.86 / psz.height)
            let fontSize = max(7, base * scale)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: Self.lit,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
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
        } else {
            dragMode = .move
            NSCursor.closedHand.set()
        }
        // While held, capture the wheel globally so minute-adjust keeps working
        // even if the cursor leaves the view during a drag.
        startScrollMonitor()
    }

    override func mouseDragged(with event: NSEvent) {
        switch dragMode {
        case .move:
            NSCursor.closedHand.set()
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
        // Restore the resting cursor for the release position (e.g. the open
        // "grab" hand over the body, not the closed "grabbing" hand).
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
        case .add1: onAdd?(1)
        case .add3: onAdd?(3)
        case .add5: onAdd?(5)
        }
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

    // MARK: Zoom (hover + wheel)

    // Hovering + wheel zooms the watch *around the cursor*: the point under the
    // pointer keeps its exact relative position, so whatever you point at stays
    // put while the size changes. (Press-drag + wheel still adjusts minutes via
    // the event tap, which consumes the wheel before it reaches here.)
    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 16
        guard dy != 0 else { return }
        // Scroll up → zoom in, down → zoom out (up reads as a negative delta, same
        // convention as the minute-adjust wheel). Exponential so it feels uniform.
        let factor = CGFloat(exp(Double(-dy) * 0.0035))
        zoomWindow(by: factor, around: NSEvent.mouseLocation)
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
    // (behind verified private selectors) and the standard open-hand for moving.
    private static let moveCursor = NSCursor.openHand
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
