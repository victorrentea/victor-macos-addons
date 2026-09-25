import AppKit

/// 📏 **⌘⌃; — the „șubler"**: a ruler over every screen, to measure pixels.
///
/// The key opens a transparent sheet over all screens with a crosshair and two
/// hairlines through the pointer (edges are lined up against those before the
/// drag starts). Dragging draws a box and reads its size **in pixels** — the
/// physical ones, so a 2× retina reads double what the points say, and the
/// points ride along in grey whenever the two differ, because the number a
/// Swift/CSS frame is written in is the point. ⇧ while dragging locks the drag
/// to its dominant axis: a straight line, the ruletă proper.
///
/// The box **stays after the mouse is let go** so the number can be read at
/// leisure; the next drag replaces it. Esc, a right-click or ⌘⌃; again closes
/// the ruler and hands the keyboard back to the app that had it.
///
/// Nothing is measured *from the pixels themselves* (no edge detection, no
/// screen capture): no Screen Recording grant is needed, and the ruler never
/// makes a claim about the picture that the eye cannot check.
final class ScreenRuler {
    static let shared = ScreenRuler()

    private var panels: [RulerPanel] = []
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    var isOpen: Bool { !panels.isEmpty }

    /// Main thread only.
    func toggle() {
        isOpen ? close() : open()
    }

    /// Main thread only. `from`/`to` in global Cocoa points draw a measurement
    /// straight away — the `/test/ruler` hook, so the readout can be checked
    /// without taking the mouse from Victor.
    func open(from: NSPoint? = nil, to: NSPoint? = nil) {
        if !isOpen {
            previousApp = NSWorkspace.shared.frontmostApplication
            panels = NSScreen.screens.map { RulerPanel(screen: $0, onClose: { [weak self] in self?.close() }) }
            panels.forEach { $0.orderFrontRegardless() }
            // The panels must be key to see Esc, which means this app has to be
            // active — an accessory app that is not in front gets no key events.
            NSApp.activate(ignoringOtherApps: true)
            panels.first { $0.screen == screenUnderMouse() }?.makeKey()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {   // Esc
                    self?.close()
                    return nil
                }
                return event
            }
        }
        if let from, let to {
            for panel in panels { panel.rulerView.measure(fromGlobal: from, toGlobal: to) }
        }
    }

    /// Main thread only.
    func close() {
        guard isOpen else { return }
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}

/// The arithmetic of a measurement, apart from any view so it can be tested.
enum RulerGeometry {
    /// The box between the two ends of a drag, in points. With `lockAxis` the
    /// shorter side collapses to zero — a straight horizontal or vertical line.
    static func box(from a: NSPoint, to b: NSPoint, lockAxis: Bool) -> NSRect {
        var end = b
        if lockAxis {
            if abs(b.x - a.x) >= abs(b.y - a.y) { end.y = a.y } else { end.x = a.x }
        }
        return NSRect(x: min(a.x, end.x), y: min(a.y, end.y),
                      width: abs(end.x - a.x), height: abs(end.y - a.y))
    }

    /// `480 × 72 px`, then `240 × 36 pt` in grey when the screen is not 1×.
    /// Rounded rather than truncated: a pointer on a retina sits on half
    /// points, and 119.5 pt is 239 px, not 238.
    static func readout(size: NSSize, scale: CGFloat) -> (pixels: String, points: String?) {
        let px = "\(Int((size.width * scale).rounded())) × \(Int((size.height * scale).rounded())) px"
        guard scale != 1 else { return (px, nil) }
        return (px, "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt")
    }
}

private final class RulerPanel: NSPanel {
    let rulerView: RulerView

    init(screen: NSScreen, onClose: @escaping () -> Void) {
        rulerView = RulerView(frame: NSRect(origin: .zero, size: screen.frame.size),
                              screenOrigin: screen.frame.origin,
                              scale: screen.backingScaleFactor,
                              onClose: onClose)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = rulerView
    }

    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class RulerView: NSView {
    private let screenOrigin: NSPoint
    private let scale: CGFloat
    private let onClose: () -> Void

    private var cursor: NSPoint?
    private var anchor: NSPoint?
    private var box: NSRect?

    private static let ink = NSColor.systemPink
    private static let pxFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    private static let ptFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    init(frame: NSRect, screenOrigin: NSPoint, scale: CGFloat, onClose: @escaping () -> Void) {
        self.screenOrigin = screenOrigin
        self.scale = scale
        self.onClose = onClose
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// A measurement given in global coordinates; drawn only on the screen it
    /// starts on.
    func measure(fromGlobal a: NSPoint, toGlobal b: NSPoint) {
        let local = { (p: NSPoint) in NSPoint(x: p.x - self.screenOrigin.x, y: p.y - self.screenOrigin.y) }
        guard bounds.contains(local(a)) else { box = nil; needsDisplay = true; return }
        box = RulerGeometry.box(from: local(a), to: local(b), lockAxis: false)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        box = NSRect(origin: anchor!, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursor = point
        box = RulerGeometry.box(from: anchor, to: point, lockAxis: event.modifierFlags.contains(.shift))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        anchor = nil
    }

    override func rightMouseDown(with event: NSEvent) { onClose() }

    override func draw(_ dirtyRect: NSRect) {
        // A breath of tint, so it is obvious the ruler is up — and so the whole
        // screen takes clicks (a fully clear window lets them through).
        NSColor(white: 0, alpha: 0.06).setFill()
        bounds.fill()

        if let cursor, anchor == nil {
            let guides = NSBezierPath()
            guides.move(to: NSPoint(x: 0, y: cursor.y.rounded() + 0.5))
            guides.line(to: NSPoint(x: bounds.maxX, y: cursor.y.rounded() + 0.5))
            guides.move(to: NSPoint(x: cursor.x.rounded() + 0.5, y: 0))
            guides.line(to: NSPoint(x: cursor.x.rounded() + 0.5, y: bounds.maxY))
            guides.lineWidth = 1 / scale
            Self.ink.withAlphaComponent(0.55).setStroke()
            guides.stroke()
        }

        guard let box else { return }
        Self.ink.withAlphaComponent(0.12).setFill()
        box.fill()
        let outline = NSBezierPath(rect: box)
        outline.lineWidth = 1 / scale
        Self.ink.setStroke()
        outline.stroke()
        drawReadout(for: box)
    }

    private func drawReadout(for box: NSRect) {
        let (px, pt) = RulerGeometry.readout(size: box.size, scale: scale)
        let text = NSMutableAttributedString(string: px, attributes: [.font: Self.pxFont, .foregroundColor: NSColor.white])
        if let pt {
            text.append(NSAttributedString(string: "   " + pt,
                                           attributes: [.font: Self.ptFont, .foregroundColor: NSColor(white: 0.75, alpha: 1)]))
        }
        let size = text.size()
        let pill = NSSize(width: size.width + 20, height: size.height + 10)
        // Under the box, centred; above it when there is no room below.
        var origin = NSPoint(x: box.midX - pill.width / 2, y: box.minY - pill.height - 8)
        if origin.y < 4 { origin.y = box.maxY + 8 }
        origin.x = min(max(4, origin.x), bounds.maxX - pill.width - 4)
        origin.y = min(origin.y, bounds.maxY - pill.height - 4)
        let rect = NSRect(origin: origin, size: pill)
        NSColor(white: 0.08, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        text.draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 5))
    }
}
