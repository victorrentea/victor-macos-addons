import AppKit
import QuartzCore

enum ScreenCaptureFlash {
    private static var activePanels: [NSPanel] = []

    /// The built-in (Retina) display, falling back to the main screen.
    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Take every live border down immediately. Called before an interactive
    /// crop: the flash is a real window, so a border still fading on screen
    /// would be selected into the crop the user is about to drag.
    static func cancelAll() {
        for panel in activePanels { panel.orderOut(nil) }
        activePanels.removeAll()
    }

    // MARK: - Suppression (while a crosshair selection is up)

    private static let suppressLock = NSLock()
    private static var suppressDepth = 0

    /// Hold off *screen-sized* flashes until `endSuppression`.
    ///
    /// Cancelling what is already up is not enough on the hold path: the crop
    /// starts on the keyUp, while the full-screen shot the same press fired is
    /// still encoding — so its border goes up a beat **later**, i.e. straight
    /// over a crosshair that is already waiting for the drag. That is wrong to
    /// look at (a whole-screen frame around a selection you are still making)
    /// and worse than cosmetic: our panel is ordered front over screencapture's
    /// own selection overlay, and observed runs then ended with the selection
    /// cancelled and no file written.
    static func beginSuppression() {
        suppressLock.lock(); suppressDepth += 1; suppressLock.unlock()
        DispatchQueue.main.async { cancelAll() }
    }

    static func endSuppression() {
        suppressLock.lock(); suppressDepth = max(0, suppressDepth - 1); suppressLock.unlock()
    }

    private static var isSuppressed: Bool {
        suppressLock.lock(); defer { suppressLock.unlock() }
        return suppressDepth > 0
    }

    static func flash(on screen: NSScreen, duration: CFTimeInterval = 1.5, thickness: CGFloat = 30, color: NSColor = .systemYellow) {
        // A crosshair selection owns the screen right now; the crop draws its
        // own border when it lands.
        guard !isSuppressed else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let size = screen.frame.size
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        for edge in edgeGradients(size: size, thickness: thickness, color: color) {
            view.layer?.addSublayer(edge)
        }

        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()

        activePanels.append(panel)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        view.layer?.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            panel.orderOut(nil)
            activePanels.removeAll { $0 === panel }
        }
    }

    // **A crop has no border, since 2026-09-09.** `flash(around:)` used to draw
    // this same fading ring inside the selected rectangle, and Victor took it
    // out of both apps in one breath: the box he dragged is the receipt, drawn
    // at the pixels he drew it around, and a ring lit over those pixels
    // afterwards covers the very thing he framed to look at. The full-screen
    // flash below stays — one keypress, no gesture, nothing else to say it
    // happened.

    /// Mark the spot the cursor was standing on when the shutter went, with a
    /// single solid yellow disc: it appears already centred on the point at
    /// 100 pt, blooms out to 250 pt while fading, and is gone in ~0.6 s. It is
    /// the "tap indicator" the Android emulator draws over a touch point.
    ///
    /// The border says *what* was captured; this says *where you were pointing*
    /// while you said whatever the transcript recorded at that minute.
    ///
    /// **It was the minigun's red aiming reticle until 2026-09-09**
    /// (`EmojiAnimator.makeSniperReticle` at half its aiming scale, alive for 2 s),
    /// and reusing that mark was deliberate — it is the shape this desktop already
    /// means "here" with. Two things were wrong with it anyway. A reticle **is** a
    /// crosshair, and a crosshair is what the other half of this very feature uses
    /// for *choosing* a region (`CropSelectionOverlay`): one shape was saying "pick
    /// a point" on the hold path and "here is the point" on the tap path. And it
    /// *sat* there at rest for most of its two seconds, on top of the very line or
    /// button being described — a shape that holds still over the thing it points
    /// at is something to wait out, while a bloom uncovers those pixels with the
    /// same motion that makes it noticeable, and is over in half a second. That is
    /// all it needs to be: "did that catch where I was pointing?" is answered by
    /// the first frame, not by how long the mark lingers.
    ///
    /// Walkie Talkie reached the same place first and it is why this looks like it
    /// does: it round-robined this disc, concentric spikes and the classic reticle
    /// through every real capture for two days and settled on the disc on
    /// 2026-09-06 (`CaptureFlash.markerRotation` / `CaptureEffect.tapRipple` there).
    /// The two apps are two halves of one gesture — Victor shoots with both, minutes
    /// apart, in the same workshop — so a shot marks its spot the same way in both.
    /// The values below are that effect's, unchanged, deliberately: matching it
    /// approximately would be worse than not matching it at all.
    ///
    /// **The panel is the whole screen under the point**, not a box around it. A
    /// box sized to the disc's *start* clips the bloom a third of the way out, and
    /// one sized to its *end* hangs 125 pt past a nearby display edge — and the
    /// displays here touch edge-to-edge, so that spills onto the neighbour instead
    /// of falling off the world. A screen-sized panel clips the bloom at the screen,
    /// which is the honest answer.
    ///
    /// `point` is in global Cocoa coordinates.
    static func markCursor(at point: NSPoint, duration: CFTimeInterval = 0.6) {
        guard !isSuppressed else { return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
                ?? NSScreen.main else { return }

        let panel = NSPanel(contentRect: screen.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        activePanels.append(panel)

        // Screen-local, bottom-left origin: CALayers on an unflipped view share
        // `NSScreen.frame`'s convention once the screen's own origin is out.
        let target = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)

        let startDiameter: CGFloat = 100
        let endDiameter: CGFloat = 250
        let base = CGRect(x: -startDiameter / 2, y: -startDiameter / 2,
                          width: startDiameter, height: startDiameter)
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: base, transform: nil)
        dot.bounds = base
        dot.position = target
        dot.fillColor = NSColor.systemYellow.cgColor
        dot.strokeColor = nil
        dot.opacity = 0
        view.layer?.addSublayer(dot)

        let group = CAAnimationGroup()
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = endDiameter / startDiameter

        // In fast, held at full strength while it is still visibly growing, then
        // out over the second half of the growth — so what the eye catches is the
        // spreading, not the arriving.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 0.6, 0.6, 0.0]
        fade.keyTimes = [0.0, 0.15, 0.4, 1.0]

        group.animations = [grow, fade]
        dot.add(group, forKey: "tap")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2) {
            panel.orderOut(nil)
            activePanels.removeAll { $0 === panel }
        }
    }

    /// Four bands hugging the edges of `size`, each solid on its outer edge and
    /// fading to nothing inward — the shape both flashes are made of.
    private static func edgeGradients(size: CGSize, thickness: CGFloat, color: NSColor) -> [CAGradientLayer] {
        let solid = color.cgColor
        let clear = color.withAlphaComponent(0).cgColor

        func band(_ frame: CGRect, from: CGPoint, to: CGPoint) -> CAGradientLayer {
            let layer = CAGradientLayer()
            layer.frame = frame
            layer.colors = [solid, clear]
            layer.startPoint = from
            layer.endPoint = to
            return layer
        }

        return [
            // Top: solid at the top → clear downward
            band(CGRect(x: 0, y: size.height - thickness, width: size.width, height: thickness),
                 from: CGPoint(x: 0.5, y: 1.0), to: CGPoint(x: 0.5, y: 0.0)),
            // Bottom: solid at the bottom → clear upward
            band(CGRect(x: 0, y: 0, width: size.width, height: thickness),
                 from: CGPoint(x: 0.5, y: 0.0), to: CGPoint(x: 0.5, y: 1.0)),
            // Left: solid at the left → clear rightward
            band(CGRect(x: 0, y: 0, width: thickness, height: size.height),
                 from: CGPoint(x: 0.0, y: 0.5), to: CGPoint(x: 1.0, y: 0.5)),
            // Right: solid at the right → clear leftward
            band(CGRect(x: size.width - thickness, y: 0, width: thickness, height: size.height),
                 from: CGPoint(x: 1.0, y: 0.5), to: CGPoint(x: 0.0, y: 0.5)),
        ]
    }

}
