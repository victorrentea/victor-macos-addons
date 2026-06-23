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
        epoch += 1
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

    /// A short, decaying left↔right shake of the whole watch (used on each gong
    /// strike at expiry to simulate the gong's vibration).
    private func shakeWatch() {
        guard let layer = panel?.contentView?.layer else { return }
        let n = 26
        let amp: CGFloat = 16
        let values: [NSNumber] = (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n - 1)
            return NSNumber(value: Double(amp * exp(-3.2 * t) * sin(t * .pi * 9)))
        }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = values
        shake.duration = 0.85
        shake.isAdditive = true
        shake.calculationMode = .cubic
        layer.add(shake, forKey: "shake")
    }

    // MARK: - Activity-driven backdrop

    /// While the user is active (mouse/keyboard within the last 5s) the opaque
    /// backdrop fades fully away — only the outlined digits remain. After 5s
    /// idle it fades back to fully opaque. One smooth fade per transition, so
    /// it never flickers.
    private func startActivityMonitor() {
        activityTimer?.invalidate()
        bgOpaque = true
        bgView?.alphaValue = 1
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.setBackgroundOpaque(Self.systemIdleSeconds() >= 5.0)
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
        let secondStrike = 0.8
        let gong = SoundManager.shared.soundDuration("50_gong.mp3") ?? 3.0

        SoundManager.shared.playOverlapping("50_gong.mp3")   // strike 1
        shakeWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + secondStrike) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            SoundManager.shared.playOverlapping("50_gong.mp3")   // strike 2
            self.shakeWatch()
        }
        // Stay on screen until the second gong sound has fully played out.
        DispatchQueue.main.asyncAfter(deadline: .now() + secondStrike + gong) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            self.close()
        }
    }

    private static func defaultFrame() -> NSRect {
        // "Main screen" = the primary display (menu-bar screen, origin .zero) —
        // NSScreen.main is the *focused* screen, which may be an external monitor.
        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = vf.width * 0.16
        let h = w / aspect
        let margin = vf.width * 0.02
        return NSRect(x: vf.maxX - w - margin, y: vf.maxY - h - margin, width: w, height: h)
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

    // Red LED look — colors sampled from the reference: a deep red for lit
    // segments and a solid very-dark red for the unlit (ghost) segments.
    private static let lit = NSColor(calibratedRed: 0.847, green: 0.196, blue: 0.224, alpha: 1.0)
    private static let ghost = NSColor(calibratedRed: 0.137, green: 0.031, blue: 0.039, alpha: 1.0)

    // The colon dots live on their own layer so they can pulse gently (1.0↔0.5
    // every second) on the GPU, independent of the digit redraws.
    private let colonLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        colonLayer.fillColor = Self.lit.cgColor
        colonLayer.strokeColor = NSColor.black.cgColor
        colonLayer.lineWidth = 2
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.5
        pulse.duration = 0.5            // 0.5s down + 0.5s up = 1s gentle cycle
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        colonLayer.add(pulse, forKey: "pulse")
        layer?.addSublayer(colonLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(digits: String, finishLocal: String, finishCET: String, paused: Bool) {
        self.digits = digits
        self.finishLocal = finishLocal
        self.finishCET = finishCET
        self.paused = paused
        needsDisplay = true
    }

    func setDigitsVisible(_ visible: Bool) {
        digitsVisible = visible
        needsDisplay = true
    }

    /// The resize corners and the control buttons are shown only while the mouse
    /// hovers the timer; `hoveredButton` highlights the button under the cursor.
    private var mouseInside = false
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
        let bottomH = b.height * 0.22
        let bottomY = pad * 0.9            // bottom margin (+50%)

        // Digits area + the x of the digits' left edge (labels align to this).
        // Content margins increased 50% on all four edges.
        let hInset = b.width * 0.06
        let topInset = b.height * 0.12
        let digitsBottom = bottomY + bottomH + b.height * 0.03
        let digitsArea = NSRect(x: hInset, y: digitsBottom,
                                width: b.width - 2 * hInset,
                                height: max(0, b.height - topInset - digitsBottom))
        let dscale = min(digitsArea.height / Self.cellH, digitsArea.width / Self.contentW)
        let digitsLeftX = digitsArea.midX - (Self.contentW * dscale) / 2
        let digitsRightX = digitsLeftX + Self.contentW * dscale   // right edge of the last digit

        // Finish-time labels: left-aligned to the digits' left margin.
        let labelRight = ch + b.width * 0.40
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
        drawDigits(in: L.digits)
        drawLabels(in: L.label)
        // Controls and resize handles appear only while hovering the panel.
        if mouseInside {
            for (rect, kind) in L.buttons { drawButton(kind, rect: rect) }
            drawResizeCorners()
        }
    }

    /// Red L-brackets at the 4 corners — shown while hovering — marking (and
    /// providing a fat target for) the resize corners.
    private func drawResizeCorners() {
        let b = bounds
        let len = max(10, min(b.width, b.height) * 0.10)
        let i: CGFloat = 3
        let p = NSBezierPath()
        p.lineWidth = 4.5          // 3x thicker, easy to click
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: i, y: i + len));            p.line(to: NSPoint(x: i, y: i));            p.line(to: NSPoint(x: i + len, y: i))
        p.move(to: NSPoint(x: b.width - i - len, y: i));  p.line(to: NSPoint(x: b.width - i, y: i));  p.line(to: NSPoint(x: b.width - i, y: i + len))
        p.move(to: NSPoint(x: i, y: b.height - i - len)); p.line(to: NSPoint(x: i, y: b.height - i)); p.line(to: NSPoint(x: i + len, y: b.height - i))
        p.move(to: NSPoint(x: b.width - i - len, y: b.height - i)); p.line(to: NSPoint(x: b.width - i, y: b.height - i)); p.line(to: NSPoint(x: b.width - i, y: b.height - i - len))
        Self.lit.setStroke()
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
        // Each lit segment gets a 2px black outline so it reads on any backdrop.
        guard digitsVisible else { return }
        let on = Self.segments[c] ?? []
        for seg in on {
            guard let pts = Self.segPolys[seg] else { continue }
            let path = segPath(pts, cellX: cellX, originY: originY, scale: scale)
            Self.lit.setFill(); path.fill()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
        }
    }

    private func updateColonLayer(cx: CGFloat, originY: CGFloat, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // don't animate path/frame changes
        colonLayer.frame = bounds
        colonLayer.isHidden = !digitsVisible    // hide with the digits during expiry blink
        let r = Self.dotR * scale
        let path = CGMutablePath()
        for yl in Self.dotCy {
            let cy = originY + (Self.cellH - yl) * scale
            path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
        colonLayer.path = path
        CATransaction.commit()
    }

    private func drawLabels(in area: NSRect) {
        guard area.height > 0 else { return }
        let fontSize = max(8, area.height * 0.34)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let local = NSAttributedString(string: finishLocal, attributes: [
            .font: font, .foregroundColor: Self.lit.withAlphaComponent(0.95),
        ])
        let cet = NSAttributedString(string: finishCET, attributes: [
            .font: font, .foregroundColor: Self.lit.withAlphaComponent(0.55),
        ])
        // Left-aligned to the digits' left margin (area.minX == digits' left edge).
        local.draw(at: NSPoint(x: area.minX, y: area.minY + area.height * 0.52))
        cet.draw(at: NSPoint(x: area.minX, y: area.minY + area.height * 0.06))
    }

    private func drawButton(_ kind: BreakButtonKind, rect r: NSRect) {
        let pressed = pressedButton == kind
        let hovered = hoveredButton == kind
        let bgAlpha: CGFloat = pressed ? 0.32 : (hovered ? 0.20 : 0.10)
        Self.lit.withAlphaComponent(bgAlpha).setFill()
        Self.lit.withAlphaComponent(0.30).setStroke()
        let bg = NSBezierPath(roundedRect: r, xRadius: r.height * 0.25, yRadius: r.height * 0.25)
        bg.fill()
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
        // Restore the resting cursor for the release position (e.g. the open
        // "grab" hand over the body, not the closed "grabbing" hand).
        let L = computeLayout()
        if let corner = cornerHit(p, L) { Self.cursor(forCorner: corner).set() }
        else if buttonHit(p, L) != nil { NSCursor.pointingHand.set() }
        else { Self.moveCursor.set() }
    }

    override func scrollWheel(with event: NSEvent) {
        // While grabbing the timer body, the wheel adds/subtracts minutes.
        guard case .move = dragMode else { return }
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            scrollAccum += dy
            while scrollAccum >= 20 { onAdd?(1); scrollAccum -= 20 }
            while scrollAccum <= -20 { onAdd?(-1); scrollAccum += 20 }
        } else {
            onAdd?(dy > 0 ? 1 : -1)   // one minute per wheel notch
        }
    }

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
        needsDisplay = true
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        hoveredButton = nil
        needsDisplay = true
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
