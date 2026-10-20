import AppKit
import QuartzCore
import VictorMacKit

/// 🔦 ⇧ + wheel-drag — **plain glass over the whole screen except one box**,
/// whose edges melt into the glass instead of stopping at a line. Esc takes it
/// away. Victor, 2026-10-04: *"să las vizibilă doar acea zonă din ecran …
/// restul de zone din ecran să fie cu efect de glass, iar marginile zonei mele
/// să fie cumva blurate, nu brusc trecute la glass."*
///
/// **The gesture is the crop's**, and so is the code that reads it: ⌘ moves the
/// box instead of resizing it, and the box never leaves the
/// screen the drag started on — `RegionDrag` in victor-mac-kit, the same value
/// `CropSelectionOverlay` drives. Only the trigger differs: ⇧ has to be down when
/// the wheel goes down, and from then on it is not needed any more.
/// While the glass is up, ⌘ at the press instead of ⇧ grabs the box that is
/// there and carries it, whatever the drag does (Victor, 2026-10-05).
///
/// **Why here and not in victor-effects**, though it is an effect: that repo is
/// public and cannot depend on the private kit the gesture lives in; and the
/// zoom it most needs to agree with, `ShareZoom`, is in this process.
///
/// **Both zooms, by where the window sits.** The panel is *under*
/// `ShareZoom`'s (`.screenSaver`), so the live capture that zoom magnifies
/// contains the glass and its hole — the box is magnified together with the
/// thing it frames, exactly as macOS's own magnifier (⌥-scroll) magnifies the
/// whole framebuffer, panel included. In both, the box is drawn in **desktop**
/// coordinates, which is also what the pointer is in: neither zoom remaps input,
/// so the corner sits under the cursor the room sees.
///
/// **Scroll on the glass zooms the box** (2026-10-20, `GlassSpotlightZoom`): a
/// live picture of it grows towards the middle of the screen, up to 80% of its
/// width or height, over glass that has closed behind it. Moving or resizing
/// waits until it is scrolled back out.
///
/// Main thread only.
final class GlassSpotlight {

    /// One under ScreenBrush's drawing canvas, which sits at 29 (read from
    /// `CGWindowListCopyWindowInfo`, 2026-10-04).
    static let windowLevel = 28
    /// Feather, in points, *outside* the box: everything in the box stays sharp.
    /// 40 until 2026-10-20, halved at Victor's word (*"the transitions from glass
    /// to full transparency have half the thickness"*).
    static let feather: CGFloat = 20
    /// A drag puts the glass up *while it is still under way* only once its box
    /// covers this much of the screen, and from then on keeps it up however small
    /// the box gets again — never the whole screen blurred first and the box
    /// revealed from nothing (Victor, 2026-10-04). A smaller box gets its glass on
    /// release (`revealsOnRelease`).
    static let revealFraction: CGFloat = 0.05

    /// How close to a corner of the box a bare wheel press has to land to pick
    /// that corner up again — inside the box or out on the feather, either way.
    static let cornerReach: CGFloat = 60
    /// …but no deeper than this into the box, which stays clickable: a corner
    /// zone is the glass's, and the glass takes no clicks.
    static let cornerInside: CGFloat = 16

    /// The glass comes and goes over this long, its blur growing (or melting)
    /// with its opacity, so it settles rather than appears (Victor, 2026-10-20:
    /// *"it should be a progressive animation, not immediately"*). It was a
    /// 0.15 s / 0.2 s opacity fade.
    static let fadeInSeconds: Double = 0.6
    static let fadeOutSeconds: Double = 0.45
    /// The dashed outline's fade once the wheel comes up — about as long as the
    /// glass takes to settle (Victor: *"the dashed rectangle fades out as the
    /// glass effect settles"*).
    static let outlineFadeSeconds: Double = 0.6

    static func reveals(_ box: CGRect, on screen: CGRect) -> Bool {
        box.width * box.height >= revealFraction * screen.width * screen.height
    }

    /// **On release, any box at all puts the glass up** — `revealFraction` only
    /// decides whether it comes up *during* the drag (Victor, 2026-10-20: *"there
    /// should not be any lower limit to the surface that I need to select … anything
    /// I have selected is going to show up as visible on a surface of glass"*). Only
    /// a press that never opened a box (a ⇧-click) changes nothing.
    static let minimumSide: CGFloat = 2

    static func revealsOnRelease(_ box: CGRect) -> Bool {
        box.width >= minimumSide && box.height >= minimumSide
    }

    /// The box on the glass, in global **CG** coordinates (y down, as events
    /// carry them), nil when there is none — so the tap can tell whether a bare
    /// wheel press landed on one of its corners.
    var onHoleChanged: ((CGRect?) -> Void)?

    /// Called on every change of `isShowing`, so the event tap can tell whether
    /// Esc is ours.
    var onShowingChanged: ((Bool) -> Void)?
    private(set) var isShowing = false {
        didSet { if isShowing != oldValue { onShowingChanged?(isShowing) } }
    }

    /// The glass's screen, global CG — the tap asks whether a scroll landed on it.
    var onScreenChanged: ((CGRect) -> Void)?
    /// Called on every change of `isZoomed`: while zoomed, the tap takes every
    /// bare scroll on the glass's screen and leaves the box's corners and ⌘ alone.
    var onZoomedChanged: ((Bool) -> Void)?
    /// The box is (or is about to be) magnified. It cannot be moved or resized
    /// then (Victor, 2026-10-20: *"I cannot move the selection while I'm zooming"*);
    /// a new ⇧ drag drops the zoom and starts over.
    private(set) var isZoomed = false {
        didSet { if isZoomed != oldValue { onZoomedChanged?(isZoomed) } }
    }

    private var panel: SpotlightPanel?
    private var glass: PlainGlassView?
    private var glassScreen: NSScreen?
    private var screenFrame: CGRect = .zero

    /// The dashed outline and the `⌘ move` legend, in a window of their own over
    /// the glass: they are up during a drag before any glass is (its first 5%),
    /// and the glass's fade must not fade them with it. Never takes the mouse.
    private var decoPanel: SpotlightPanel?
    private var decoFrame: CGRect = .zero
    private let outline = CAShapeLayer()
    private let legend = CATextLayer()
    private let legendPill = CALayer()
    private var decoHide: DispatchWorkItem?

    /// The drag under the hand, nil between drags.
    private var drag: RegionDrag?
    /// The screen the drag began on, and whether its box has reached
    /// `revealFraction` yet — until then the glass is left as the drag found it.
    private var dragScreen: NSScreen?
    private var revealed = false
    /// The box as the drag last drew it, glass or not yet.
    private var dragBox: CGRect?
    /// This drag carries the box already up (⌘ at the press) rather than
    /// drawing a new one: the whole drag is a ⌘ move, held or not.
    private var grabbing = false
    /// Where the tap last saw the pointer (global Cocoa). Preferred over
    /// `NSEvent.mouseLocation`, for the reason `CropSelectionOverlay.dragMoved`
    /// gives: the event's own position, not wherever a starved timer finds it.
    private var pushed: NSPoint?
    /// The box on the glass right now (global Cocoa), and the one before this
    /// drag began — a drag too small to be a box puts that one back.
    private var hole: CGRect? {
        didSet { if hole != oldValue { onHoleChanged?(hole.map(Self.cg)) } }
    }
    private var holeBeforeDrag: CGRect?
    private var maskedHole: CGRect?
    private var timer: Timer?
    /// While the glass is up and no drag is on: where the pointer is decides
    /// whether the panel takes the click (glass, corners) or lets it through
    /// (the box), and which cursor shows.
    private var hoverTimer: Timer?
    private let cursors = GlassSpotlightCursors()

    /// How far the glass is up, 0…1, and where it is heading (`fade`).
    private var level: CGFloat = 0
    private var levelTarget: CGFloat = 0
    private var fadeTimer: Timer?
    private var fadeLast: CFAbsoluteTime = 0

    /// The zoom (`GlassSpotlightZoom`): the box's live picture, and how far it
    /// has travelled towards the middle — eased towards the wheel's target.
    private let lens = GlassSpotlightLens()
    private var zoom: CGFloat = 0
    private var zoomTarget: CGFloat = 0
    private var zoomBox: CGRect?
    /// The picture has its first frame and lies over unbroken glass. Until then
    /// the cut-out stays and the zoom waits, so it never starts from a blank.
    private var lensLive = false
    private var zoomTimer: Timer?

    init() {
        lens.onLive = { [weak self] in self?.lensWentLive() }
        lens.onFailed = { [weak self] reason in
            overlayError("🔦 glass spotlight zoom: \(reason)")
            self?.endZoom()
        }
    }

    // MARK: - Driven by the event tap

    /// The wheel went down with ⇧ held. Global CG coordinates (y down), as the
    /// event carries them.
    func begin(atCG point: CGPoint) {
        let p = Self.cocoa(point)
        guard let screen = NSScreen.physical.first(where: { NSMouseInRect(p, $0.frame, false) })
                ?? NSScreen.main else { return }
        if isZoomed { endZoom() }   // a new box is drawn on unmagnified glass
        holeBeforeDrag = screenFrame == screen.frame ? hole : nil
        dragScreen = screen
        revealed = false
        grabbing = false
        drag = RegionDrag(anchor: p, within: screen.frame, controlArmed: true)
        dragBox = nil
        pushed = p
        ensureDeco(on: screen)
        startTimer()
        tick()
    }

    /// The wheel went down with ⌘ held while the glass is up: the box already
    /// there follows the hand, kept on its own screen, from wherever the press
    /// was. ⌘ may be let go once the drag has started, as ⇧ may for `begin`.
    func grab(atCG point: CGPoint) {
        guard isShowing, !isZoomed, let box = hole, let glassScreen else { return }
        let p = Self.cocoa(point)
        holeBeforeDrag = box
        dragScreen = nil
        revealed = true
        grabbing = true
        var drag = RegionDrag(anchor: box.origin, within: screenFrame, controlArmed: true)
        drag.regrip(anchor: box.origin, free: CGPoint(x: box.maxX, y: box.maxY), mouse: p)
        self.drag = drag
        pushed = p
        ensureDeco(on: glassScreen)
        startTimer()
        tick()
    }

    /// A bare wheel press on a corner of the box already up (the tap checked
    /// it is within `cornerReach`): the drag left off there resumes — that
    /// corner follows the hand, the opposite one stays, and ⌘ held at any point
    /// carries the whole box, as in the drag that drew it (Victor, 2026-10-06:
    /// *"let's resume what we were cropping"*).
    func resume(atCG point: CGPoint) {
        let p = Self.cocoa(point)
        guard isShowing, !isZoomed, let box = hole, let glassScreen,
              let corner = GlassSpotlightCorners.corner(of: box, near: p, reach: .greatestFiniteMagnitude) else { return }
        holeBeforeDrag = box
        dragScreen = nil
        revealed = true
        grabbing = false
        // The press need not be exactly on the corner: the offset is kept, so
        // nothing jumps at the press.
        var drag = RegionDrag(anchor: GlassSpotlightCorners.opposite(corner, in: box), within: screenFrame,
                              controlArmed: true)
        drag.regrip(anchor: GlassSpotlightCorners.opposite(corner, in: box), free: corner, mouse: p)
        self.drag = drag
        pushed = p
        ensureDeco(on: glassScreen)
        startTimer()
        tick()
    }

    func moved(toCG point: CGPoint) {
        guard drag != nil else { return }
        pushed = Self.cocoa(point)
        tick()
    }

    /// The wheel came up: the box stays, the hand is free, the outline fades.
    func end(atCG point: CGPoint) {
        guard drag != nil else { return }
        pushed = Self.cocoa(point)
        tick()
        stopTimer()
        drag = nil
        grabbing = false
        if !revealed, let dragScreen, let box = dragBox, Self.revealsOnRelease(box) {
            revealed = true
            ensurePanel(on: dragScreen)
            apply(hole: box)
        }
        legendPill.isHidden = true
        fadeOutline()
        if !isShowing { cursors.release() }   // with the glass up, `hover` takes the cursor back
        guard revealed, let box = hole else {
            overlayInfo("🔦 glass spotlight: no box drawn, "
                        + (holeBeforeDrag == nil ? "no glass" : "previous box kept"))
            return
        }
        overlayInfo("🔦 glass spotlight: \(Int(box.width))×\(Int(box.height)) at (\(Int(box.minX)),\(Int(box.minY)))")
    }

    /// A bare scroll the tap found on this glass (or anywhere on its screen,
    /// zoomed): `notches` closer (+) or farther (−), `ShareZoomPolicy.notches`.
    func scroll(notches: CGFloat) {
        guard isShowing, drag == nil, let box = hole else { return }
        setZoom(GlassSpotlightZoom.step(zoomTarget, notches: notches), box: box)
    }

    /// Esc: the glass goes, whatever state it is in — a zoomed box with it.
    func dismiss() {
        stopTimer()
        drag = nil
        hole = nil
        holeBeforeDrag = nil
        legendPill.isHidden = true
        fadeOutline()
        stopZoomTimer()
        isZoomed = false
        guard panel != nil, isShowing else {
            resetZoom()
            return
        }
        isShowing = false
        stopHover()
        fade(to: 0)
        overlayInfo("🔦 glass spotlight: off")
    }

    // MARK: - Headless (`/test/glass-spotlight`)

    /// Put a box up without the mouse — global Cocoa rect — or take it down.
    func testShow(_ rect: CGRect?) -> String {
        if let rect,
           let screen = NSScreen.physical.first(where: { NSMouseInRect(CGPoint(x: rect.midX, y: rect.midY), $0.frame, false) }) {
            stopTimer()
            drag = nil
            if isZoomed { endZoom() }
            ensurePanel(on: screen)
            legendPill.isHidden = true
            apply(hole: rect.intersection(screen.frame))
        } else if rect == nil {
            dismiss()
        }
        return snapshotJSON()
    }

    /// `?zoom=0…1`: the wheel's target, set directly.
    func testZoom(_ target: CGFloat) -> String {
        if isShowing, drag == nil, let box = hole { setZoom(min(1, max(0, target)), box: box) }
        return snapshotJSON()
    }

    func snapshotJSON() -> String {
        let r = hole ?? .zero
        let z = zoomBox.map { GlassSpotlightZoom.frame(box: $0, screen: screenFrame, progress: zoom) } ?? .zero
        return """
        {"showing":\(isShowing),"dragging":\(drag != nil),\
        "hole":[\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))],\
        "screen":[\(Int(screenFrame.minX)),\(Int(screenFrame.minY)),\(Int(screenFrame.width)),\(Int(screenFrame.height))],\
        "level":\(panel?.level.rawValue ?? 0),"glass":\(String(format: "%.2f", level)),\
        "zoomed":\(isZoomed),"lensLive":\(lensLive),"lensFrames":\(lens.framesShown),\
        "zoom":\(String(format: "%.3f", zoom)),"zoomTarget":\(String(format: "%.3f", zoomTarget)),\
        "zoomFrame":[\(Int(z.minX)),\(Int(z.minY)),\(Int(z.width)),\(Int(z.height))]}
        """
    }

    // MARK: - The loop

    /// Pushed positions draw on arrival; the timer is for what only it can see —
    /// ⌘ going down or up while the mouse stands still, and Esc should
    /// the tap ever have stopped answering.
    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard var drag else { return }
        if CGEventSource.keyState(.combinedSessionState, key: 53) { dismiss(); return }
        let flags = NSEvent.modifierFlags
        let mouse = pushed ?? NSEvent.mouseLocation
        // No ⌃ square here, unlike the crop: Victor, 2026-10-04, *"n-am nevoie de square"*.
        let box = drag.update(mouse: mouse, command: grabbing || flags.contains(.command), control: false)
        self.drag = drag
        dragBox = box
        if drag.moving {
            cursors.show(.move)
        } else {
            let free = drag.freeCorner(for: mouse)
            // Cocoa y is up: a free corner up-right or down-left of the anchor is the ↗↙ diagonal.
            cursors.show((free.x - drag.anchor.x) * (free.y - drag.anchor.y) > 0 ? .resizeNESW : .resizeNWSE)
        }
        // The outline from the first pixel, glass or not yet.
        renderDecorations(box: box, moving: drag.moving)
        if !revealed {
            guard let dragScreen, Self.reveals(box, on: dragScreen.frame) else { return }
            revealed = true
            ensurePanel(on: dragScreen)
        }
        apply(hole: box)
    }

    // MARK: - Hover: clicks and cursor while the glass is up

    private func startHover() {
        guard hoverTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.hover() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func stopHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        panel?.ignoresMouseEvents = true
        cursors.release()
    }

    private func hover() {
        guard drag == nil, let panel, let box = hole else { return }
        let p = NSEvent.mouseLocation
        guard NSMouseInRect(p, screenFrame, false) else {
            cursors.release()
            return
        }
        if isZoomed {
            // The box is under glass now, its picture is not a window: nothing
            // on this screen is clickable until the zoom is scrolled back out.
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            cursors.show(.arrow)
            return
        }
        let corner = GlassSpotlightCorners.corner(of: box, near: p, reach: Self.cornerReach, inside: Self.cornerInside)
        let inBox = corner == nil && box.contains(p)
        if panel.ignoresMouseEvents != inBox { panel.ignoresMouseEvents = inBox }
        // ⌘ held = a wheel drag from anywhere moves the box (the tap takes ⌘-middle
        // while the glass is up), so the four arrows show everywhere, the box
        // included — the invitation to press the wheel (Victor, 2026-10-06). The
        // box stays click-through, so ⌘-click still reaches the app under it; that
        // app may put its own cursor back on a move, and the next tick re-sets ours.
        let flags = NSEvent.modifierFlags.intersection([.command, .shift, .control, .option])
        if flags == .command {
            cursors.show(.move)
        } else if let corner {
            // The corner's diagonal: bottom-left and top-right are ↗↙ (Cocoa, y up).
            cursors.show((corner.x == box.minX) == (corner.y == box.minY) ? .resizeNESW : .resizeNWSE)
        } else if inBox {
            cursors.release()   // the app under the box draws its own
        } else {
            cursors.show(.arrow)
        }
    }

    // MARK: - Showing and hiding the glass

    private func ensurePanel(on screen: NSScreen) {
        if panel == nil || screenFrame != screen.frame {
            panel?.orderOut(nil)
            build(on: screen)
            level = 0
        }
        guard let panel else { return }
        if !isShowing {
            resetZoom()   // a zoom still fading out with the last glass
            hole = nil
            maskedHole = nil
            applyLevel()
            panel.orderFrontRegardless()
            decoPanel?.orderFrontRegardless()   // the outline stays over the glass
            isShowing = true
            startHover()
            fade(to: 1)
        }
    }

    /// Up or down from wherever the glass is now, so a ⇧ drag during a fade-out
    /// turns it around instead of starting over.
    private func fade(to target: CGFloat) {
        levelTarget = target
        guard fadeTimer == nil else { return }
        fadeLast = CFAbsoluteTimeGetCurrent()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.fadeTick() }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func fadeTick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = CGFloat(now - fadeLast)
        fadeLast = now
        let up = levelTarget > level
        let step = dt / CGFloat(up ? Self.fadeInSeconds : Self.fadeOutSeconds)
        level = up ? min(levelTarget, level + step) : max(levelTarget, level - step)
        applyLevel()
        guard level == levelTarget else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        if level == 0, !isShowing {
            panel?.orderOut(nil)
            if drag == nil { decoPanel?.orderOut(nil) }
            resetZoom()
            maskedHole = nil
        }
    }

    /// Opacity and blur radius move together: at a third of the way the glass is
    /// a third as opaque *and* a third as blurred — a focus pull, not a curtain.
    private func applyLevel() {
        let eased = level * level * (3 - 2 * level)
        panel?.alphaValue = eased
        glass?.radius = PlainGlassView.blurRadius * Double(eased)
        glass?.tune()
    }

    // MARK: - Zoom

    private func setZoom(_ target: CGFloat, box: CGRect) {
        guard target != zoomTarget else { return }
        zoomTarget = target
        if target > 0, !isZoomed { startZoom(box) }
        if target == 0, !lensLive {
            endZoom()   // scrolled back out before the picture ever came
            return
        }
        startZoomTimer()
    }

    private func startZoom(_ box: CGRect) {
        guard let glassScreen else { return }
        isZoomed = true
        zoomBox = box
        zoom = 0
        lensLive = false
        let capture = GlassSpotlightZoom.capture(box: box, feather: Self.feather, screen: screenFrame)
        let l = lens.layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.isHidden = true
        l.transform = CATransform3DIdentity
        l.bounds = CGRect(origin: .zero, size: capture.size)
        // Scaled about the box's own centre, which is what slides to the screen's.
        l.anchorPoint = CGPoint(x: (box.midX - capture.minX) / capture.width,
                                y: (box.midY - capture.minY) / capture.height)
        l.position = CGPoint(x: box.midX - screenFrame.minX, y: box.midY - screenFrame.minY)
        let mask = CALayer()
        mask.frame = l.bounds
        mask.contents = GlassSpotlightMask.image(canvas: capture.size,
                                                 hole: box.offsetBy(dx: -capture.minX, dy: -capture.minY),
                                                 feather: Self.feather, scale: glassScreen.backingScaleFactor,
                                                 inverted: true)
        l.mask = mask
        CATransaction.commit()
        lens.start(filming: capture, on: glassScreen)
    }

    /// The first frame is in: the picture, unmagnified, goes over the cut-out
    /// it matches pixel for pixel, the glass closes under it, and only then does
    /// the zoom begin to move.
    private func lensWentLive() {
        guard isZoomed, let glass else { return }
        lensLive = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lens.layer.isHidden = false
        CATransaction.commit()
        glass.maskImage = nil
        maskedHole = nil
        glass.tune()
        startZoomTimer()
    }

    private func startZoomTimer() {
        guard zoomTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.zoomTick() }
        RunLoop.main.add(t, forMode: .common)
        zoomTimer = t
    }

    private func stopZoomTimer() {
        zoomTimer?.invalidate()
        zoomTimer = nil
    }

    private func zoomTick() {
        guard lensLive, let box = zoomBox else { return }
        zoom = GlassSpotlightZoom.ease(zoom, toward: zoomTarget)
        let s = GlassSpotlightZoom.scale(box: box, screen: screenFrame, progress: zoom)
        let c = GlassSpotlightZoom.center(box: box, screen: screenFrame, progress: zoom)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lens.layer.position = CGPoint(x: c.x - screenFrame.minX, y: c.y - screenFrame.minY)
        lens.layer.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
        guard zoom == zoomTarget else { return }
        stopZoomTimer()
        if zoom == 0 { endZoom() }
    }

    /// Back to the cut-out: the hole first, then the picture over it goes.
    private func endZoom() {
        if isShowing, let hole { apply(hole: hole) }
        resetZoom()
    }

    private func resetZoom() {
        stopZoomTimer()
        lens.stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lens.layer.isHidden = true
        lens.layer.mask = nil
        CATransaction.commit()
        lensLive = false
        zoom = 0
        zoomTarget = 0
        zoomBox = nil
        isZoomed = false
    }

    // MARK: - Drawing

    private func build(on screen: NSScreen) {
        screenFrame = screen.frame
        glassScreen = screen
        onScreenChanged?(Self.cg(screen.frame))
        let panel = SpotlightPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        // Under ScreenBrush's canvas (29), so the ink lands on top of the glass —
        // Victor draws over what the box frames; above the menu bar (24/25) and
        // the Dock, so the glass is still everything but the box. Far under
        // `ShareZoom`'s `.screenSaver`, so that zoom magnifies the glass with
        // everything else (see the type comment).
        panel.level = NSWindow.Level(rawValue: GlassSpotlight.windowLevel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The glass takes every click and scroll — nothing under it is reachable
        // (Victor, 2026-10-06: *"the masked area shouldn't be clickable at all"*);
        // `hover` makes the panel click-through only while the pointer is in the
        // box. Non-activating and never key, so a click on the glass does nothing.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let glass = PlainGlassView(frame: root.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.blendingMode = .behindWindow
        glass.material = .fullScreenUI
        glass.state = .active
        root.addSubview(glass)

        // The zoomed picture, over the glass and in the same window, so it fades
        // with it.
        let lensHost = NSView(frame: root.bounds)
        lensHost.autoresizingMask = [.width, .height]
        lensHost.wantsLayer = true
        lens.layer.removeFromSuperlayer()
        lens.layer.isHidden = true
        lensHost.layer?.addSublayer(lens.layer)
        root.addSubview(lensHost)

        panel.contentView = root
        self.panel = panel
        self.glass = glass
        maskedHole = nil
    }

    /// The outline's window on `screen`, in front, the outline fully drawn.
    private func ensureDeco(on screen: NSScreen) {
        decoHide?.cancel()
        decoHide = nil
        if decoPanel == nil || decoFrame != screen.frame {
            decoPanel?.orderOut(nil)
            buildDeco(on: screen)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.removeAllAnimations()
        outline.path = nil
        outline.opacity = 1
        CATransaction.commit()
        decoPanel?.orderFrontRegardless()
    }

    private func buildDeco(on screen: NSScreen) {
        decoFrame = screen.frame
        let panel = SpotlightPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        panel.level = NSWindow.Level(rawValue: GlassSpotlight.windowLevel)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        // The crop's own colour, dashed: the box's exact edge while the hand is
        // on it — the feather hides where it really is (Victor, 2026-10-20:
        // *"should be a dotted line border as I crop my screen … I have to have
        // precision"*).
        outline.removeFromSuperlayer()
        outline.fillColor = nil
        outline.strokeColor = CropSelectionStyle().accent.cgColor
        outline.lineWidth = 2
        outline.lineDashPattern = [6, 4]
        outline.shadowColor = NSColor.black.cgColor
        outline.shadowOpacity = 0.5
        outline.shadowRadius = 1.5
        outline.shadowOffset = .zero
        view.layer?.addSublayer(outline)
        legendPill.removeFromSuperlayer()
        legendPill.isHidden = true
        legend.contentsScale = screen.backingScaleFactor
        legend.alignmentMode = .center
        if legend.superlayer == nil { legendPill.addSublayer(legend) }
        view.layer?.addSublayer(legendPill)
        panel.contentView = view
        decoPanel = panel
    }

    /// The wheel is up: the outline fades while the glass settles; with no glass
    /// to settle (a drag under 5%) its window goes too.
    private func fadeOutline() {
        let from = outline.presentation()?.opacity ?? outline.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.removeAllAnimations()
        outline.opacity = 0
        CATransaction.commit()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = 0
        anim.duration = Self.outlineFadeSeconds
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        outline.add(anim, forKey: "fade")
        decoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.drag == nil else { return }
            self.decoPanel?.orderOut(nil)
        }
        decoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outlineFadeSeconds + 0.1, execute: work)
    }

    /// Cut `box` (global Cocoa) out of the glass.
    private func apply(hole box: CGRect) {
        hole = box
        guard let glass, maskedHole != box else { return }
        maskedHole = box
        let local = box.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        // A drawing-handler image, not a bitmap: `NSVisualEffectView` reads a
        // bitmap mask's pixels as backing pixels whatever size the `NSImage`
        // claims, so on Retina the mask came out at half size, pinned to the
        // top-right — the hole up, right of and smaller than the drag
        // (2026-10-04). A handler is drawn at whatever density the view asks for.
        let size = screenFrame.size
        glass.maskImage = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            GlassSpotlightMask.draw(in: ctx, canvas: size, hole: local, feather: Self.feather)
            return true
        }
        glass.tune()
    }

    /// While the hand is on it: the dashed outline on the box's edge, and the
    /// crop's `⌘ move` under it, brighter while ⌘ is held — straight on the
    /// glass, no plate behind it (Victor, 2026-10-04: *"deseneaz-o pe blur fără
    /// fundal negru, discret"*). The outline goes when the hand does.
    private func renderDecorations(box: CGRect, moving: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let local = box.offsetBy(dx: -decoFrame.minX, dy: -decoFrame.minY)
        // Just outside the box, so the dashes never sit on what it frames.
        outline.path = CGPath(rect: local.insetBy(dx: -1, dy: -1), transform: nil)

        let style = CropSelectionStyle()
        let text = NSAttributedString(string: style.movingSuffix, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: moving ? 0.9 : 0.5)])
        legend.string = text
        let measured = text.size()
        let size = CGSize(width: measured.width.rounded(.up), height: measured.height.rounded(.up))
        legend.frame = CGRect(origin: .zero, size: size)
        let bounds = CGRect(origin: .zero, size: decoFrame.size)
        var y = local.minY - size.height - 8
        if y < 4 { y = min(local.maxY + 8, bounds.height - size.height - 4) }
        let x = min(max(local.midX - size.width / 2, 4), max(4, bounds.width - size.width - 4))
        legendPill.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        legendPill.isHidden = false
    }

    private static func cocoa(_ cg: CGPoint) -> NSPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: cg.x, y: top - cg.y)
    }

    private static func cg(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Plain glass: the effect view's own behind-window blur, turned down until text
/// is still readable but takes effort, with the material's grey layers hidden.
/// Victor, 2026-10-06, after a frosted version (tint + grain + lit rim): *"it's
/// like sand … just plain glass, more transparent and without any border … the
/// text should be barely readable. Still readable, but harder."*
///
/// **Private, and degrades to the stock look.** The radius is the `gaussianBlur`
/// filter on the `CABackdropLayer` AppKit builds inside the view (30 pt stock),
/// set by key path; `scale` is how coarsely the backdrop samples (⅛ stock,
/// which turns a small radius into blocks). `fill` (50% grey) and `tone` are the
/// material's tint. Measured side by side 2026-10-06 on this Mac (macOS 15) at
/// r 1.5–6 × scale ⅛–1: r 3 at ½ is the "readable with effort" one. Should a
/// macOS update rename any of these, nothing throws — the glass just goes back
/// to the heavy grey blur.
final class PlainGlassView: NSVisualEffectView {
    static let blurRadius: Double = 3
    static let backdropScale: Double = 0.5
    /// The radius `tune` applies: `blurRadius`, except while `GlassSpotlight`
    /// fades the glass in or out and walks it up from (or down to) zero.
    var radius: Double = PlainGlassView.blurRadius

    override func updateLayer() {
        super.updateLayer()
        tune()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tune()
    }

    /// Idempotent; AppKit may rebuild the material's layers (appearance change,
    /// a new screen), so it is reapplied whenever the view redraws.
    func tune() {
        func walk(_ layer: CALayer) {
            if layer.name == "fill" || layer.name == "tone" { layer.isHidden = true }
            if layer.name == "backdrop",
               (layer.filters ?? []).contains(where: { ($0 as? NSObject)?.value(forKey: "name") as? String == "gaussianBlur" }) {
                layer.setValue(radius, forKeyPath: "filters.gaussianBlur.inputRadius")
                layer.setValue(Self.backdropScale, forKey: "scale")
            }
            layer.sublayers?.forEach(walk)
        }
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        walk(layer)
        CATransaction.commit()
    }
}

/// Never key, never main, never pushed under the menu bar — the frame handed
/// in is a screen's own (same reasons as `CropPanel` in victor-mac-kit).
private final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Which corner of the box a press picks up. Pure, and indifferent to which
/// way y points, so the tap (CG) and the spotlight (Cocoa) share it.
enum GlassSpotlightCorners {
    /// The corner of `box` nearest `point`, if it is within `reach` of it and
    /// no deeper than `inside` into the box.
    static func corner(of box: CGRect, near point: CGPoint, reach: CGFloat,
                       inside: CGFloat = .greatestFiniteMagnitude) -> CGPoint? {
        if box.insetBy(dx: inside, dy: inside).contains(point) { return nil }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
        let nearest = corners.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }!
        return hypot(nearest.x - point.x, nearest.y - point.y) <= reach ? nearest : nil
    }

    /// The corner across the box from `corner`: the one that stays put.
    static func opposite(_ corner: CGPoint, in box: CGRect) -> CGPoint {
        CGPoint(x: corner.x == box.minX ? box.maxX : box.minX,
                y: corner.y == box.minY ? box.maxY : box.minY)
    }
}

/// The cursor over the glass, set from a background app.
///
/// **The way out of "a background app cannot set the cursor"** is the window
/// server's `SetsCursorInBackground` connection property (private; what
/// cursor-changing utilities use). Measured 2026-10-06: without it,
/// `NSCursor.set()` from this accessory app left Terminal's I-beam on screen;
/// with it, the resize cursor showed. If the call ever fails the cursor simply
/// stays whatever the app underneath set.
///
/// It holds because nothing else is setting the cursor at the same time: over
/// the glass the panel takes the mouse, so the app under it gets no mouse-moved
/// to answer with its own; during a wheel drag the tap swallows the drags.
final class GlassSpotlightCursors {
    enum Shape { case arrow, resizeNWSE, resizeNESW, move }

    private var shown: Shape?
    private static let enabled: Bool = {
        let cid = _CGSDefaultConnection()
        return CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    func show(_ shape: Shape) {
        guard Self.enabled else { return }
        // Set every tick, not only on a change: an app under the box may have
        // put its own back since.
        shown = shape
        Self.cursor(shape).set()
    }

    /// Stop drawing ours; the next app the pointer moves over sets its own.
    func release() {
        guard shown != nil else { return }
        shown = nil
        NSCursor.arrow.set()
    }

    private static func cursor(_ shape: Shape) -> NSCursor {
        switch shape {
        case .arrow: return .arrow
        case .move: return move
        case .resizeNWSE:
            if #available(macOS 15, *) { return NSCursor.frameResize(position: .topLeft, directions: .all) }
            return .crosshair
        case .resizeNESW:
            if #available(macOS 15, *) { return NSCursor.frameResize(position: .topRight, directions: .all) }
            return .crosshair
        }
    }

    /// Four arrows — AppKit has no public move cursor. Black on a white halo,
    /// the same look as the system's own resize cursors.
    private static let move: NSCursor = {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            func symbol(_ weight: NSFont.Weight, _ points: CGFloat, _ color: NSColor) -> NSImage? {
                let config = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
                    .applying(.init(paletteColors: [color]))
                return NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                               accessibilityDescription: nil)?.withSymbolConfiguration(config)
            }
            for (image, inset) in [(symbol(.black, 19, .white), 0.0), (symbol(.semibold, 15, .black), 2.5)] {
                guard let image else { continue }
                let r = rect.insetBy(dx: inset, dy: inset)
                let size = image.size
                let scale = min(r.width / size.width, r.height / size.height)
                let draw = CGSize(width: size.width * scale, height: size.height * scale)
                image.draw(in: CGRect(x: r.midX - draw.width / 2, y: r.midY - draw.height / 2,
                                      width: draw.width, height: draw.height))
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()
}

@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// The glass's alpha: opaque everywhere, clear inside the box, and a smooth
/// ramp across `feather` points *outside* it. Pure, so it is tested by reading
/// pixels back rather than by looking at a screen.
enum GlassSpotlightMask {
    /// An alpha-only image of `canvas` (points, y up), at `scale` pixels a point —
    /// what the tests read back; the glass itself draws straight into its mask.
    ///
    /// `inverted` is the zoomed picture's own mask (`GlassSpotlightZoom`): opaque in
    /// the box, fading out across the feather — the cut-out's exact complement, so
    /// the picture laid over unbroken glass looks like the hole it replaces.
    static func image(canvas: CGSize, hole: CGRect, feather: CGFloat, scale: CGFloat = 1,
                      inverted: Bool = false) -> CGImage? {
        let width = max(1, Int((canvas.width * scale).rounded(.up)))
        let height = max(1, Int((canvas.height * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx, canvas: canvas, hole: hole, feather: feather, steps: Int(feather * scale), inverted: inverted)
        return ctx.makeImage()
    }

    /// The mask's alpha into `ctx`, in points, `steps` rings across the feather.
    /// Opaque past the feather: a lighter glass (0.75, tried 2026-10-04) let the
    /// sharp text through enough to read it — *"trebuie să fie greu de citit"*.
    static func draw(in ctx: CGContext, canvas: CGSize, hole: CGRect, feather: CGFloat, steps: Int = 64,
                     inverted: Bool = false) {
        ctx.setBlendMode(.copy)
        ctx.setFillColor(gray: 0, alpha: inverted ? 0 : 1)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        // Concentric rounded rects from the feather's outer edge in to the box,
        // each one *replacing* the alpha under it (`.copy`): one step a point,
        // too fine to band. Smoothstep, so the ramp has no visible start or end.
        let steps = max(1, min(64, steps))
        for i in 0...steps {
            let f = CGFloat(steps - i) / CGFloat(steps)        // 1 at the outer edge → 0 at the box
            let glass = f * f * (3 - 2 * f)
            let alpha = inverted ? 1 - glass : glass
            let rect = hole.insetBy(dx: -feather * f, dy: -feather * f)
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(feather * f, rect.width / 2, rect.height / 2)
            ctx.setFillColor(gray: 0, alpha: alpha)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }
}
