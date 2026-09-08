import AppKit
import QuartzCore

/// The crosshair crop's selection UI (⌃P **held**) — ours, in place of
/// `screencapture -i`.
///
/// **Why we stopped using the system's crosshair.** The selection had to learn
/// one thing macOS's own only offers on the **space bar**: a box you are still
/// dragging can be *moved* whole, instead of resized. `screencapture -i` cannot
/// be told to read ⌘ for that, and translating ⌘ into a synthetic space keypress
/// means posting a key into a subprocess that owns the screen — one that
/// arrives, if the modifier leaks, as ⌘Space, i.e. Spotlight over the workshop's
/// projector. There is also nothing in it that can be asked to keep the box
/// *inside the screen*, which is the other half of the request.
///
/// Owning the selection pays for itself twice over: the crop rectangle is now
/// **known**, not reconstructed. The old `CropDragTracker` sampled
/// `CGEventSource.buttonState` every 8 ms behind screencapture's overlay purely
/// to guess where the drag had been, and the confirmation border then had to be
/// checked against the saved file's pixel dimensions before it dared draw
/// itself. Both are gone: we hand the exact rectangle to the capture *and* to
/// the border.
///
/// **How it is driven.** Not by AppKit's mouse events but by a 60 Hz poll of
/// session input state — `NSEvent.mouseLocation`, `CGEventSource.buttonState`,
/// `NSEvent.modifierFlags`, `CGEventSource.keyState` — the same technique the
/// drag tracker used, and for the same reason: it needs no key window, no app
/// activation and no focus stolen from whatever the room is looking at. The
/// panels still *accept* mouse events (they just drop them), which is what keeps
/// the drag from selecting text in the app underneath.
final class CropSelectionOverlay {
    struct Selection {
        /// Global Cocoa coordinates, whole points, entirely within `screen`.
        let rect: NSRect
        let screen: NSScreen
    }

    /// Nothing smaller than this is a selection — it is a click that slipped.
    private static let minimumSide: CGFloat = 6

    private static var active: CropSelectionOverlay?

    /// Put the crosshair up. `completion` runs on the main thread, **after** the
    /// overlay is off the screen and the window server has had time to forget
    /// it — the capture that follows must not photograph our own dimming.
    static func begin(completion: @escaping (Selection?) -> Void) {
        if active != nil { completion(nil); return }
        let overlay = CropSelectionOverlay(completion: completion)
        active = overlay
        overlay.show()
    }

    // MARK: - State

    private let completion: (Selection?) -> Void
    private var panels: [(panel: NSPanel, view: CropOverlayView, screen: NSScreen)] = []
    private var timer: Timer?

    /// The corner that stays put while the mouse drags the other one.
    private var anchor: NSPoint = .zero
    /// Free corner = mouse + this. Zero until an edge refuses to let the box
    /// follow the cursor; then it carries exactly how far behind it fell.
    private var freeOffset: CGVector = .zero
    private var dragging = false
    private var startScreen: NSScreen?
    /// Set on the ⌘ press, cleared on the release: where the mouse and the box
    /// were when the move began, so the translation is always measured from
    /// there rather than accumulated.
    private var moveOrigin: (mouse: NSPoint, anchor: NSPoint, free: NSPoint)?
    private var finished = false

    private init(completion: @escaping (Selection?) -> Void) {
        self.completion = completion
    }

    // MARK: - Lifecycle

    private func show() {
        for screen in NSScreen.screens {
            let panel = CropPanel(contentRect: screen.frame,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            // Accepting the mouse is the whole point of the window: the clicks
            // of the drag must land here and nowhere else.
            panel.ignoresMouseEvents = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = CropOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       scale: screen.backingScaleFactor)
            panel.contentView = view
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append((panel, view, screen))
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func finish(_ selection: Selection?) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        for entry in panels { entry.panel.orderOut(nil) }

        // The panels are gone from AppKit's point of view; the compositor needs
        // a beat before the pixels behind them are what a capture would see.
        let done = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            CropSelectionOverlay.active = nil
            done(selection)
        }
        panels.removeAll()
    }

    // MARK: - The loop

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let leftDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let rightDown = CGEventSource.buttonState(.combinedSessionState, button: .right)
        let escape = CGEventSource.keyState(.combinedSessionState, key: 53)

        // Esc and right-click both mean "never mind": no file, clipboard and
        // folder left exactly as they were.
        if escape || rightDown { finish(nil); return }

        guard dragging else {
            if leftDown {
                startDrag(at: mouse)
            } else {
                render(selection: nil, cursor: mouse, moving: false)
            }
            return
        }

        guard let bounds = startScreen?.frame else { finish(nil); return }
        let moving = NSEvent.modifierFlags.contains(.command)

        if moving, moveOrigin == nil {
            moveOrigin = (mouse: mouse, anchor: anchor, free: freeCorner(for: mouse))
        } else if !moving {
            moveOrigin = nil
        }

        if let origin = moveOrigin {
            // ⌘ held: the box travels with the mouse instead of being resized —
            // and stops at the edges of its own screen rather than walking off.
            let raw = CGVector(dx: mouse.x - origin.mouse.x, dy: mouse.y - origin.mouse.y)
            let box = CropFlashGeometry.rect(from: origin.anchor, to: origin.free)
            let delta = CropFlashGeometry.clampedTranslation(of: box, by: raw, within: bounds)
            anchor = NSPoint(x: origin.anchor.x + delta.dx, y: origin.anchor.y + delta.dy)
            freeOffset = CGVector(dx: origin.free.x + delta.dx - mouse.x,
                                  dy: origin.free.y + delta.dy - mouse.y)
        }

        let rect = CropFlashGeometry.rect(from: anchor, to: freeCorner(for: mouse))
        render(selection: rect, cursor: mouse, moving: moving)

        guard !leftDown else { return }

        // Mouse up: this is the crop.
        let final = CropFlashGeometry.rounded(rect)
        guard let screen = startScreen,
              final.width >= Self.minimumSide, final.height >= Self.minimumSide else {
            finish(nil)
            return
        }
        finish(Selection(rect: final, screen: screen))
    }

    private func startDrag(at mouse: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { finish(nil); return }
        startScreen = screen
        anchor = CropFlashGeometry.clamped(mouse, within: screen.frame)
        freeOffset = .zero
        moveOrigin = nil
        dragging = true
    }

    /// The corner the mouse is dragging, held inside the starting screen.
    private func freeCorner(for mouse: NSPoint) -> NSPoint {
        let raw = NSPoint(x: mouse.x + freeOffset.dx, y: mouse.y + freeOffset.dy)
        guard let bounds = startScreen?.frame else { return raw }
        return CropFlashGeometry.clamped(raw, within: bounds)
    }

    // MARK: - Drawing

    private func render(selection: NSRect?, cursor: NSPoint, moving: Bool) {
        for entry in panels {
            let origin = entry.screen.frame.origin
            let local = selection.map { NSRect(x: $0.minX - origin.x, y: $0.minY - origin.y,
                                               width: $0.width, height: $0.height) }
            entry.view.render(selection: local,
                              cursor: NSPoint(x: cursor.x - origin.x, y: cursor.y - origin.y),
                              size: selection.map { CGSize(width: $0.width.rounded(), height: $0.height.rounded()) },
                              moving: moving)
        }
    }
}

/// Borderless, and deliberately never key: the overlay is watched, not typed
/// into, and stealing the keyboard from the app behind it would outlive the
/// selection.
private final class CropPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One screen's worth of overlay. Layers, not `draw(_:)`: the only thing that
/// changes 60 times a second is a path and a string, and repainting a retina
/// screen's worth of dimming to move a rectangle is how a crosshair starts to
/// feel heavy.
private final class CropOverlayView: NSView {
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let vGuide = CALayer()
    private let hGuide = CALayer()
    private let sizeLabel: PillLabel
    private let hint: PillLabel

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let hintFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let accent = NSColor.systemYellow

    init(frame: NSRect, scale: CGFloat) {
        sizeLabel = PillLabel(font: Self.labelFont, scale: scale)
        hint = PillLabel(font: Self.hintFont, scale: scale)
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor

        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        root.addSublayer(dim)

        border.fillColor = nil
        border.strokeColor = Self.accent.cgColor
        border.lineWidth = 2
        root.addSublayer(border)

        for guide in [vGuide, hGuide] {
            guide.backgroundColor = Self.accent.withAlphaComponent(0.55).cgColor
            root.addSublayer(guide)
        }

        root.addSublayer(sizeLabel.layer)
        root.addSublayer(hint.layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The panel accepts clicks purely so the app underneath never sees the
    /// drag; the selection itself is read from session input state.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func render(selection: NSRect?, cursor: NSPoint, size: CGSize?, moving: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection { path.addRect(selection) }
        dim.path = path

        if let selection, let size {
            border.isHidden = false
            border.path = CGPath(rect: selection.insetBy(dx: -1, dy: -1), transform: nil)
            border.lineWidth = moving ? 3 : 2
            vGuide.isHidden = true
            hGuide.isHidden = true
            hint.layer.isHidden = true
            place(sizeLabel,
                  text: "\(Int(size.width)) × \(Int(size.height))\(moving ? "   ✥ mut" : "")",
                  near: selection)
        } else {
            border.isHidden = true
            // Before the drag there is no box to look at, so the crosshair is
            // the whole screen's width and height crossing under the pointer —
            // ours, drawn, because the arrow belongs to whatever app is in front.
            vGuide.isHidden = false
            hGuide.isHidden = false
            vGuide.frame = CGRect(x: cursor.x.rounded(), y: 0, width: 1, height: bounds.height)
            hGuide.frame = CGRect(x: 0, y: cursor.y.rounded(), width: bounds.width, height: 1)
            sizeLabel.layer.isHidden = true
            // The hold is the one gesture nothing on screen reveals; ⌘ is the
            // second. Say both once, while there is still nothing else to read.
            place(hint, text: "trage o zonă  ·  ⌘ mută selecția  ·  Esc anulează",
                  near: nil, cursor: cursor)
        }
    }

    /// The readout sits just under the selection, flipping above it when the box
    /// is against the bottom of the screen — never inside it, where it would be
    /// captured.
    private func place(_ pill: PillLabel, text: String, near rect: NSRect?, cursor: NSPoint = .zero) {
        let size = pill.setText(text)
        var x: CGFloat
        var y: CGFloat
        if let rect {
            x = rect.midX - size.width / 2
            y = rect.minY - size.height - 6
            if y < 4 { y = min(rect.maxY + 6, bounds.height - size.height - 4) }
        } else {
            x = cursor.x + 16
            y = cursor.y - size.height - 16
            if y < 4 { y = cursor.y + 16 }
        }
        pill.layer.frame = CGRect(x: min(max(x, 4), max(4, bounds.width - size.width - 4)),
                                  y: min(max(y, 4), max(4, bounds.height - size.height - 4)),
                                  width: size.width, height: size.height)
    }
}

/// A rounded dark pill with one line of text vertically centred in it.
/// `CATextLayer` draws from the top of its own box, so the text gets a layer of
/// its own inside the background rather than a frame fudged to look centred.
private final class PillLabel {
    let layer = CALayer()
    private let text = CATextLayer()
    private let font: NSFont
    private static let padding = CGSize(width: 9, height: 5)

    init(font: NSFont, scale: CGFloat) {
        self.font = font
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer.cornerRadius = 5
        layer.isHidden = true
        text.contentsScale = scale
        text.font = font
        text.fontSize = font.pointSize
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.isWrapped = false
        text.truncationMode = .none
        layer.addSublayer(text)
    }

    /// Sets the string and answers the pill size the caller has to place.
    @discardableResult
    func setText(_ string: String) -> CGSize {
        layer.isHidden = false
        text.string = string
        let measured = (string as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: measured.width + Self.padding.width * 2,
                          height: measured.height + Self.padding.height * 2)
        text.frame = CGRect(x: 0, y: Self.padding.height,
                            width: size.width, height: measured.height)
        return size
    }
}
