import AppKit
import QuartzCore
import VictorMacKit

/// 🔦 ⇧ + wheel-drag — **frosted glass over the whole screen except one box**,
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
/// Main thread only.
final class GlassSpotlight {

    /// One under ScreenBrush's drawing canvas, which sits at 29 (read from
    /// `CGWindowListCopyWindowInfo`, 2026-10-04).
    static let windowLevel = 28
    /// Feather, in points, *outside* the box: everything in the box stays sharp.
    static let feather: CGFloat = 40
    /// A drag puts the glass up only once its box covers this much of the screen,
    /// and from then on keeps it up however small the box gets again — never the
    /// whole screen blurred first and the box revealed from nothing (Victor,
    /// 2026-10-04). A drag that never gets there changes nothing.
    static let revealFraction: CGFloat = 0.05

    static func reveals(_ box: CGRect, on screen: CGRect) -> Bool {
        box.width * box.height >= revealFraction * screen.width * screen.height
    }

    /// Called on every change of `isShowing`, so the event tap can tell whether
    /// Esc is ours.
    var onShowingChanged: ((Bool) -> Void)?
    private(set) var isShowing = false {
        didSet { if isShowing != oldValue { onShowingChanged?(isShowing) } }
    }

    private var panel: SpotlightPanel?
    private var glass: NSVisualEffectView?
    /// What turns the blur into frosted glass: a milky tint, grain and a sheen,
    /// cut by the same feathered hole as the blur (`frostMask`).
    private let frost = CALayer()
    private let frostMask = CALayer()
    /// The glass's cut edge around the box: lit from the top-left, a fine line
    /// plus a soft glow, each a gradient shown through a stroked path.
    private let rim = CAGradientLayer()
    private let rimLine = CAShapeLayer()
    private let rimGlow = CAGradientLayer()
    private let rimGlowLine = CAShapeLayer()
    private var decorations: CALayer?
    private let legend = CATextLayer()
    private let legendPill = CALayer()
    private var screenFrame: CGRect = .zero

    /// The drag under the hand, nil between drags.
    private var drag: RegionDrag?
    /// The screen the drag began on, and whether its box has reached
    /// `revealFraction` yet — until then the glass is left as the drag found it.
    private var dragScreen: NSScreen?
    private var revealed = false
    /// This drag carries the box already up (⌘ at the press) rather than
    /// drawing a new one: the whole drag is a ⌘ move, held or not.
    private var grabbing = false
    /// Where the tap last saw the pointer (global Cocoa). Preferred over
    /// `NSEvent.mouseLocation`, for the reason `CropSelectionOverlay.dragMoved`
    /// gives: the event's own position, not wherever a starved timer finds it.
    private var pushed: NSPoint?
    /// The box on the glass right now (global Cocoa), and the one before this
    /// drag began — a drag too small to be a box puts that one back.
    private var hole: CGRect?
    private var holeBeforeDrag: CGRect?
    private var maskedHole: CGRect?
    private var timer: Timer?
    private var fadeGeneration = 0

    // MARK: - Driven by the event tap

    /// The wheel went down with ⇧ held. Global CG coordinates (y down), as the
    /// event carries them.
    func begin(atCG point: CGPoint) {
        let p = Self.cocoa(point)
        guard let screen = NSScreen.physical.first(where: { NSMouseInRect(p, $0.frame, false) })
                ?? NSScreen.main else { return }
        holeBeforeDrag = screenFrame == screen.frame ? hole : nil
        dragScreen = screen
        revealed = false
        grabbing = false
        drag = RegionDrag(anchor: p, within: screen.frame, controlArmed: true)
        pushed = p
        startTimer()
        tick()
    }

    /// The wheel went down with ⌘ held while the glass is up: the box already
    /// there follows the hand, kept on its own screen, from wherever the press
    /// was. ⌘ may be let go once the drag has started, as ⇧ may for `begin`.
    func grab(atCG point: CGPoint) {
        guard isShowing, let box = hole else { return }
        let p = Self.cocoa(point)
        holeBeforeDrag = box
        dragScreen = nil
        revealed = true
        grabbing = true
        var drag = RegionDrag(anchor: box.origin, within: screenFrame, controlArmed: true)
        drag.regrip(anchor: box.origin, free: CGPoint(x: box.maxX, y: box.maxY), mouse: p)
        self.drag = drag
        pushed = p
        startTimer()
        tick()
    }

    func moved(toCG point: CGPoint) {
        guard drag != nil else { return }
        pushed = Self.cocoa(point)
        tick()
    }

    /// The wheel came up: the box stays, the hand is free.
    func end(atCG point: CGPoint) {
        guard drag != nil else { return }
        pushed = Self.cocoa(point)
        tick()
        stopTimer()
        drag = nil
        grabbing = false
        legendPill.isHidden = true
        guard revealed, let box = hole else {
            overlayInfo("🔦 glass spotlight: drag under \(Int(Self.revealFraction * 100))% of the screen, "
                        + (holeBeforeDrag == nil ? "no glass" : "previous box kept"))
            return
        }
        overlayInfo("🔦 glass spotlight: \(Int(box.width))×\(Int(box.height)) at (\(Int(box.minX)),\(Int(box.minY)))")
    }

    /// Esc: the glass goes, whatever state it is in.
    func dismiss() {
        stopTimer()
        drag = nil
        hole = nil
        holeBeforeDrag = nil
        guard let panel, isShowing else { return }
        isShowing = false
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            panel.orderOut(nil)
        })
        overlayInfo("🔦 glass spotlight: off")
    }

    // MARK: - Headless (`/test/glass-spotlight`)

    /// Put a box up without the mouse — global Cocoa rect — or take it down.
    func testShow(_ rect: CGRect?) -> String {
        if let rect,
           let screen = NSScreen.physical.first(where: { NSMouseInRect(CGPoint(x: rect.midX, y: rect.midY), $0.frame, false) }) {
            stopTimer()
            drag = nil
            ensurePanel(on: screen)
            legendPill.isHidden = true
            apply(hole: rect.intersection(screen.frame))
        } else if rect == nil {
            dismiss()
        }
        return snapshotJSON()
    }

    func snapshotJSON() -> String {
        let r = hole ?? .zero
        return """
        {"showing":\(isShowing),"dragging":\(drag != nil),\
        "hole":[\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))],\
        "screen":[\(Int(screenFrame.minX)),\(Int(screenFrame.minY)),\(Int(screenFrame.width)),\(Int(screenFrame.height))],\
        "level":\(panel?.level.rawValue ?? 0)}
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
        if !revealed {
            guard let dragScreen, Self.reveals(box, on: dragScreen.frame) else { return }
            revealed = true
            ensurePanel(on: dragScreen)
        }
        apply(hole: box)
        renderDecorations(box: box, moving: drag.moving)
    }

    // MARK: - Drawing

    private func ensurePanel(on screen: NSScreen) {
        fadeGeneration += 1   // a fade-out still running must not order the panel out under us
        if panel == nil || screenFrame != screen.frame {
            panel?.orderOut(nil)
            build(on: screen)
        }
        guard let panel else { return }
        if !isShowing {
            hole = nil
            maskedHole = nil
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
            isShowing = true
        }
    }

    private func build(on screen: NSScreen) {
        screenFrame = screen.frame
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
        // Click-through: the glass is to look at, the work goes on under it.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let glass = NSVisualEffectView(frame: root.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.blendingMode = .behindWindow
        glass.material = .fullScreenUI
        glass.state = .active
        root.addSubview(glass)

        // Frosted, not just blurred (Victor, 2026-10-06: *"acum îmi pare blur"*):
        // bathroom glass is milky, grainy and catches the light.
        let frostView = NSView(frame: root.bounds)
        frostView.autoresizingMask = [.width, .height]
        frostView.wantsLayer = true
        buildFrost(size: screen.frame.size)
        frostView.layer?.addSublayer(frost)
        for (gradient, line) in [(rimGlow, rimGlowLine), (rim, rimLine)] {
            gradient.colors = [NSColor(white: 1, alpha: 0.85).cgColor, NSColor(white: 1, alpha: 0.12).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 1)   // top-left (layers are y-up here)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            line.fillColor = nil
            line.strokeColor = NSColor.white.cgColor
            gradient.mask = line
            gradient.isHidden = true
            frostView.layer?.addSublayer(gradient)
        }
        rimLine.lineWidth = 1.5
        rimGlowLine.lineWidth = 7
        rimGlow.opacity = 0.18
        root.addSubview(frostView)

        let deco = NSView(frame: root.bounds)
        deco.autoresizingMask = [.width, .height]
        deco.wantsLayer = true
        legendPill.isHidden = true
        legend.contentsScale = screen.backingScaleFactor
        legend.alignmentMode = .center
        legendPill.addSublayer(legend)
        deco.layer?.addSublayer(legendPill)
        root.addSubview(deco)

        panel.contentView = root
        self.panel = panel
        self.glass = glass
        self.decorations = deco.layer
        maskedHole = nil
    }

    static let frostTint: CGFloat = 0.14
    static let grainAlpha: CGFloat = 0.07

    /// Tint, grain and sheen, the size of the screen, drawn once per panel.
    private func buildFrost(size: CGSize) {
        frost.frame = CGRect(origin: .zero, size: size)
        frost.sublayers?.forEach { $0.removeFromSuperlayer() }

        let tint = CALayer()
        tint.frame = frost.bounds
        tint.backgroundColor = NSColor(white: 1, alpha: Self.frostTint).cgColor
        frost.addSublayer(tint)

        // Grain: one point per noise pixel, so on the Retina a grain is 2×2 —
        // visible as texture, too fine to read as a pattern.
        let grain = CALayer()
        grain.frame = frost.bounds
        grain.contents = Self.noise(size: size)
        grain.contentsGravity = .resize
        grain.magnificationFilter = .nearest
        grain.opacity = Float(Self.grainAlpha / 0.5)
        frost.addSublayer(grain)

        // Sheen: light falling across the pane from the top-left, with one
        // brighter diagonal streak — what says "a surface" rather than "out of focus".
        let sheen = CAGradientLayer()
        sheen.frame = frost.bounds
        sheen.startPoint = CGPoint(x: 0, y: 1)
        sheen.endPoint = CGPoint(x: 1, y: 0)
        sheen.colors = [0.16, 0.04, 0.0, 0.10, 0.0, 0.0, 0.05].map { NSColor(white: 1, alpha: $0).cgColor }
        sheen.locations = [0, 0.28, 0.40, 0.46, 0.52, 0.80, 1]
        frost.addSublayer(sheen)

        frostMask.contentsGravity = .resize
        frostMask.frame = frost.bounds
        frost.mask = frostMask
    }

    /// Black and white noise with alpha ½ — the layer's opacity sets the strength.
    private static func noise(size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 2)
        var rng = SystemRandomNumberGenerator()
        for i in stride(from: 0, to: pixels.count, by: 2) {
            pixels[i] = UInt8.random(in: 0...255, using: &rng) > 127 ? 255 : 0
            pixels[i + 1] = UInt8.random(in: 0...127, using: &rng)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 16,
                       bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Cut `box` (global Cocoa) out of the glass.
    private func apply(hole box: CGRect) {
        hole = box
        guard let glass, maskedHole != box else { return }
        maskedHole = box
        let local = box.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The frost's own hole: the same feathered mask, at 1× — the ramp is
        // 40 pt of smooth gradient, nothing a Retina pixel would sharpen.
        frostMask.contents = GlassSpotlightMask.image(canvas: screenFrame.size, hole: local, feather: Self.feather)
        // The rim sits halfway across the feather, where the glass is half there.
        let edge = local.insetBy(dx: -Self.feather / 2, dy: -Self.feather / 2)
        let radius = min(Self.feather / 2, edge.width / 2, edge.height / 2)
        for (gradient, line) in [(rimGlow, rimGlowLine), (rim, rimLine)] {
            let pad = line.lineWidth
            gradient.frame = edge.insetBy(dx: -pad, dy: -pad)
            line.frame = gradient.bounds
            line.path = CGPath(roundedRect: CGRect(origin: CGPoint(x: pad, y: pad), size: edge.size),
                               cornerWidth: radius, cornerHeight: radius, transform: nil)
            gradient.isHidden = false
        }
        CATransaction.commit()
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
    }

    /// While the hand is on it: the crop's `⌘ move` under the box, brighter while
    /// ⌘ is held. Straight on the glass, no plate behind it, and no line on the
    /// edge — the cut-out is the frame (Victor, 2026-10-04: *"nu ai nevoie de
    /// marginea punctată galbenă"*, *"deseneaz-o pe blur fără fundal negru, discret"*).
    private func renderDecorations(box: CGRect, moving: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let local = box.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)

        let style = CropSelectionStyle()
        let text = NSAttributedString(string: style.movingSuffix, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: moving ? 0.9 : 0.5)])
        legend.string = text
        let measured = text.size()
        let size = CGSize(width: measured.width.rounded(.up), height: measured.height.rounded(.up))
        legend.frame = CGRect(origin: .zero, size: size)
        let bounds = CGRect(origin: .zero, size: screenFrame.size)
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
}

/// Never key, never main, never pushed under the menu bar — the frame handed
/// in is a screen's own (same reasons as `CropPanel` in victor-mac-kit).
private final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The glass's alpha: opaque everywhere, clear inside the box, and a smooth
/// ramp across `feather` points *outside* it. Pure, so it is tested by reading
/// pixels back rather than by looking at a screen.
enum GlassSpotlightMask {
    /// An alpha-only image of `canvas` (points, y up), at `scale` pixels a point —
    /// what the tests read back; the glass itself draws straight into its mask.
    static func image(canvas: CGSize, hole: CGRect, feather: CGFloat, scale: CGFloat = 1) -> CGImage? {
        let width = max(1, Int((canvas.width * scale).rounded(.up)))
        let height = max(1, Int((canvas.height * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(in: ctx, canvas: canvas, hole: hole, feather: feather, steps: Int(feather * scale))
        return ctx.makeImage()
    }

    /// The mask's alpha into `ctx`, in points, `steps` rings across the feather.
    /// Opaque past the feather: a lighter glass (0.75, tried 2026-10-04) let the
    /// sharp text through enough to read it — *"trebuie să fie greu de citit"*.
    static func draw(in ctx: CGContext, canvas: CGSize, hole: CGRect, feather: CGFloat, steps: Int = 64) {
        ctx.setBlendMode(.copy)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        // Concentric rounded rects from the feather's outer edge in to the box,
        // each one *replacing* the alpha under it (`.copy`): one step a point,
        // too fine to band. Smoothstep, so the ramp has no visible start or end.
        let steps = max(1, min(64, steps))
        for i in 0...steps {
            let f = CGFloat(steps - i) / CGFloat(steps)        // 1 at the outer edge → 0 at the box
            let alpha = f * f * (3 - 2 * f)
            let rect = hole.insetBy(dx: -feather * f, dy: -feather * f)
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(feather * f, rect.width / 2, rect.height / 2)
            ctx.setFillColor(gray: 0, alpha: alpha)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }
}
