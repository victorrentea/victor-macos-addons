import AppKit

/// Break countdown "watch" overlay: a draggable, resizable, mouse-interactive
/// panel showing a big red seven-segment MM:SS countdown over a 50%-opaque black
/// background, the finish time in two timezones, and small controls
/// (+1m / +3m / +5m / pause / close). On expiry it gongs twice, blinks twice,
/// and fades out. Unlike OverlayPanel, this panel accepts mouse events.

// MARK: - Controller

final class BreakTimerController {
    static let aspect: CGFloat = 2.0          // width / height; locked on resize
    static let minWidth: CGFloat = 200

    private var panel: BreakTimerPanel?
    private var view: BreakTimerView?

    private var remaining = 0                  // seconds
    private var paused = false
    private var freezeNow: Date?              // wall-clock frozen while paused
    private var timer: Timer?
    private var epoch = 0                      // invalidates in-flight expiry blocks

    private let cetZone = TimeZone(identifier: "Europe/Paris") ?? .current

    /// (Re)start the countdown at `minutes`. Reuses the existing window in place
    /// (keeping its position & size); a fresh window opens top-right at 25% width.
    func start(minutes: Int) {
        epoch += 1
        remaining = max(0, minutes) * 60
        paused = false
        freezeNow = nil

        let view = ensureWindow()
        view.setDigitsVisible(true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()

        startTicking()
        refresh()
    }

    func addMinutes(_ m: Int) {
        guard panel != nil else { return }
        epoch += 1                            // cancel any pending expiry sequence
        remaining += m * 60
        if paused { freezeNow = Date() }      // re-anchor frozen finish time
        view?.setDigitsVisible(true)
        panel?.alphaValue = 1
        if !paused { startTicking() }
        refresh()
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
    }

    func close() {
        epoch += 1
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    // MARK: - Internals

    private func ensureWindow() -> BreakTimerView {
        if let view { return view }
        let frame = Self.defaultFrame()
        let panel = BreakTimerPanel(contentRect: frame)
        let view = BreakTimerView(frame: NSRect(origin: .zero, size: frame.size))
        view.onClose = { [weak self] in self?.close() }
        view.onTogglePause = { [weak self] in self?.togglePause() }
        view.onAdd = { [weak self] m in self?.addMinutes(m) }
        panel.contentView = view
        self.panel = panel
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

    /// At zero: gong twice, blink the digits twice, then fade out and close.
    private func beginExpiry() {
        timer?.invalidate(); timer = nil
        let myEpoch = epoch
        SoundManager.shared.playOverlapping("50_gong.mp3")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            SoundManager.shared.playOverlapping("50_gong.mp3")
        }
        blink(remaining: 2, myEpoch: myEpoch) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            self.fadeOutAndClose(myEpoch: myEpoch)
        }
    }

    private func blink(remaining count: Int, myEpoch: Int, done: @escaping () -> Void) {
        guard epoch == myEpoch else { return }
        guard count > 0 else { done(); return }
        view?.setDigitsVisible(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            self.view?.setDigitsVisible(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.blink(remaining: count - 1, myEpoch: myEpoch, done: done)
            }
        }
    }

    private func fadeOutAndClose(myEpoch: Int) {
        guard let panel, epoch == myEpoch else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.epoch == myEpoch else { return }
            self.close()
        })
    }

    private static func defaultFrame() -> NSRect {
        // "Main screen" = the primary display (menu-bar screen, origin .zero) —
        // NSScreen.main is the *focused* screen, which may be an external monitor.
        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = vf.width * 0.25
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

    // Red LED look (see reference): bright red lit segments, dim dark-red ghost.
    private static let lit = NSColor(calibratedRed: 0.95, green: 0.13, blue: 0.10, alpha: 1.0)
    private static let ghost = NSColor(calibratedRed: 0.95, green: 0.13, blue: 0.10, alpha: 0.14)

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
        let ch = max(16, min(b.width, b.height) * 0.12)
        let bottomH = b.height * 0.24
        let bottomY = pad * 0.6

        let label = NSRect(x: ch, y: bottomY, width: b.width * 0.40, height: bottomH)

        let btnLeft = label.maxX
        let btnRight = b.width - ch
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

        let digitsBottom = bottomY + bottomH + pad * 0.4
        let digitsArea = NSRect(x: pad, y: digitsBottom,
                                width: b.width - 2 * pad,
                                height: max(0, b.height - pad - digitsBottom))

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
        let b = bounds
        NSColor.black.withAlphaComponent(0.50).setFill()
        NSBezierPath(roundedRect: b, xRadius: b.height * 0.10, yRadius: b.height * 0.10).fill()

        let L = computeLayout()
        drawDigits(in: L.digits)
        drawLabels(in: L.label)
        for (rect, kind) in L.buttons { drawButton(kind, rect: rect) }
        drawCorners(L.corners)
    }

    private func drawDigits(in area: NSRect) {
        guard area.width > 0, area.height > 0 else { return }
        let chars = Array(digits)
        // Cell metrics relative to digit height.
        // total width = digits*0.58h + colons*0.30h + gaps*0.12h
        let digitCount = chars.filter { $0 != ":" }.count
        let colonCount = chars.filter { $0 == ":" }.count
        let gapsCount = max(0, chars.count - 1)
        let widthFactor = CGFloat(digitCount) * 0.58 + CGFloat(colonCount) * 0.30 + CGFloat(gapsCount) * 0.12
        guard widthFactor > 0 else { return }
        let digitH = min(area.height, area.width / widthFactor)
        let totalW = widthFactor * digitH
        var x = area.midX - totalW / 2
        let y = area.midY - digitH / 2
        let t = digitH * 0.14
        let gap = digitH * 0.12

        for c in chars {
            if c == ":" {
                let w = digitH * 0.30
                drawColon(NSRect(x: x, y: y, width: w, height: digitH), thickness: t)
                x += w + gap
            } else {
                let w = digitH * 0.58
                drawDigit(c, in: NSRect(x: x, y: y, width: w, height: digitH), thickness: t)
                x += w + gap
            }
        }
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

    private func drawDigit(_ c: Character, in r: NSRect, thickness t: CGFloat) {
        let x0 = r.minX, y0 = r.minY, w = r.width, h = r.height
        let half = t / 2
        let gp = t * 0.18                 // gap between adjacent segment ends
        let midY = y0 + h / 2
        let xL = x0 + half + gp           // horizontal-segment span
        let xR = x0 + w - half - gp
        let cxL = x0 + half               // vertical-segment centers
        let cxR = x0 + w - half
        let upB = midY + half + gp, upT = y0 + h - half - gp   // upper verticals
        let loB = y0 + half + gp, loT = midY - half - gp       // lower verticals

        let segPaths: [Character: NSBezierPath] = [
            "a": Self.hexH(xL, xR, y0 + h - half, t),
            "g": Self.hexH(xL, xR, midY, t),
            "d": Self.hexH(xL, xR, y0 + half, t),
            "f": Self.hexV(upB, upT, cxL, t),
            "b": Self.hexV(upB, upT, cxR, t),
            "e": Self.hexV(loB, loT, cxL, t),
            "c": Self.hexV(loB, loT, cxR, t),
        ]
        let on = Self.segments[c] ?? []

        // Ghost (all off segments) first.
        Self.ghost.setFill()
        for (_, seg) in segPaths { seg.fill() }

        guard digitsVisible else { return }

        // Lit segments with a soft red glow.
        let shadow = NSShadow()
        shadow.shadowColor = Self.lit.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = t * 0.9
        shadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        Self.lit.setFill()
        for key in on { segPaths[key]?.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Horizontal seven-segment bar as an elongated hexagon (pointed left/right
    /// ends) spanning xL…xR at vertical center cy, with thickness t.
    private static func hexH(_ xL: CGFloat, _ xR: CGFloat, _ cy: CGFloat, _ t: CGFloat) -> NSBezierPath {
        let half = t / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: xL, y: cy))
        p.line(to: NSPoint(x: xL + half, y: cy + half))
        p.line(to: NSPoint(x: xR - half, y: cy + half))
        p.line(to: NSPoint(x: xR, y: cy))
        p.line(to: NSPoint(x: xR - half, y: cy - half))
        p.line(to: NSPoint(x: xL + half, y: cy - half))
        p.close()
        return p
    }

    /// Vertical seven-segment bar as an elongated hexagon (pointed top/bottom
    /// ends) spanning yB…yT at horizontal center cx, with thickness t.
    private static func hexV(_ yB: CGFloat, _ yT: CGFloat, _ cx: CGFloat, _ t: CGFloat) -> NSBezierPath {
        let half = t / 2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx, y: yT))
        p.line(to: NSPoint(x: cx + half, y: yT - half))
        p.line(to: NSPoint(x: cx + half, y: yB + half))
        p.line(to: NSPoint(x: cx, y: yB))
        p.line(to: NSPoint(x: cx - half, y: yB + half))
        p.line(to: NSPoint(x: cx - half, y: yT - half))
        p.close()
        return p
    }

    private func drawColon(_ r: NSRect, thickness t: CGFloat) {
        let radius = t * 0.7
        let cx = r.midX
        let dots = [r.minY + r.height * 0.34, r.minY + r.height * 0.66]
        let draw = { (color: NSColor) in
            color.setFill()
            for cy in dots {
                NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
        }
        draw(Self.ghost)
        if digitsVisible { draw(Self.lit) }
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
        local.draw(at: NSPoint(x: area.minX, y: area.minY + area.height * 0.52))
        cet.draw(at: NSPoint(x: area.minX, y: area.minY + area.height * 0.06))
    }

    private func drawButton(_ kind: BreakButtonKind, rect r: NSRect) {
        let pressed = pressedButton == kind
        let bgAlpha: CGFloat = pressed ? 0.28 : 0.10
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
            let text = kind == .add1 ? "+1m" : (kind == .add3 ? "+3m" : "+5m")
            let fontSize = max(7, r.height * 0.36)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: Self.lit,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
    }

    private func drawCorners(_ corners: [(NSRect, ResizeCorner)]) {
        Self.lit.withAlphaComponent(0.22).setStroke()
        for (rect, corner) in corners {
            let p = NSBezierPath()
            p.lineWidth = 1.5
            let len = rect.width * 0.5
            switch corner {
            case .bottomLeft:
                p.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3 + len)); p.line(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3)); p.line(to: NSPoint(x: rect.minX + 3 + len, y: rect.minY + 3))
            case .bottomRight:
                p.move(to: NSPoint(x: rect.maxX - 3 - len, y: rect.minY + 3)); p.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3)); p.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3 + len))
            case .topLeft:
                p.move(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 3 - len)); p.line(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 3)); p.line(to: NSPoint(x: rect.minX + 3 + len, y: rect.maxY - 3))
            case .topRight:
                p.move(to: NSPoint(x: rect.maxX - 3 - len, y: rect.maxY - 3)); p.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3)); p.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3 - len))
            }
            p.stroke()
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
            let m = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: dragStartFrame.origin.x + (m.x - dragStartMouse.x),
                                           y: dragStartFrame.origin.y + (m.y - dragStartMouse.y)))
        case .resize(let corner):
            performResize(corner)
        case .button, .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .button(let kind) = dragMode {
            let p = convert(event.locationInWindow, from: nil)
            if buttonHit(p, computeLayout()) == kind { fire(kind) }
        }
        dragMode = .none
        pressedButton = nil
        needsDisplay = true
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let L = computeLayout()
        if cornerHit(p, L) != nil {
            NSCursor.crosshair.set()
        } else if buttonHit(p, L) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
