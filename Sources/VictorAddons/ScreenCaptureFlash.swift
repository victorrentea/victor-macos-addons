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

    static func flash(on screen: NSScreen, duration: CFTimeInterval = 1.5, thickness: CGFloat = 30, color: NSColor = .systemYellow, showCameraGlyph: Bool = false) {
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

        // Centered camera glyph (white→transparent, black→border color), 30% of Ox wide,
        // at 30% opacity. Added under view.layer so it fades together with the border.
        if showCameraGlyph, let glyph = tintedCameraGlyph(tint: color) {
            let glyphW = size.width * 0.30
            let aspect = glyph.size.height / max(glyph.size.width, 1)
            let glyphH = glyphW * aspect
            let glyphLayer = CALayer()
            glyphLayer.frame = CGRect(x: (size.width - glyphW) / 2,
                                      y: (size.height - glyphH) / 2,
                                      width: glyphW, height: glyphH)
            glyphLayer.contents = glyph
            glyphLayer.contentsGravity = .resizeAspect
            glyphLayer.opacity = 0.30
            view.layer?.addSublayer(glyphLayer)
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

    /// The same fading border, but drawn **on a crop** instead of on the screen.
    /// A full-screen border after a small selection is a lie about what was
    /// captured — it says "this whole screen", when the point of the crop was
    /// that it wasn't.
    ///
    /// The ring sits **inside** `rect`, fading inward from its edges exactly the
    /// way the screen-sized flash fades in from the screen's: what lights up is
    /// then the captured pixels themselves, not the untaken ones around them.
    /// Drawn outside, it read as a frame *around* something — which is the
    /// wrong answer to "what did I just take".
    ///
    /// `rect` is in global Cocoa coordinates.
    static func flash(around rect: NSRect, duration: CFTimeInterval = 1.2, color: NSColor = .systemYellow) {
        let thickness = CropFlashGeometry.borderThickness(for: rect)
        let frame = rect

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        for edge in edgeGradients(size: frame.size, thickness: thickness, color: color) {
            view.layer?.addSublayer(edge)
        }

        panel.contentView = view
        panel.setFrame(frame, display: true)
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

    /// Drop the minigun's red reticle on the spot the cursor was standing when
    /// the shutter went — it pops in, holds, and fades out inside ~2 s.
    ///
    /// The border says *what* was captured; this says *where you were pointing*
    /// while you said whatever the transcript recorded at that minute. Reusing
    /// the aiming reticle (`EmojiAnimator.makeSniperReticle`) is deliberate: it
    /// is already the mark this desktop uses for "here", so it needs no learning.
    ///
    /// `point` is in global Cocoa coordinates.
    static func markCursor(at point: NSPoint, duration: CFTimeInterval = 2.0) {
        guard !isSuppressed else { return }

        // Half the minigun's aiming scale: that one has to be found while you
        // are moving the mouse, this one only has to mark a spot you are
        // already looking at.
        let reticle = EmojiAnimator.makeSniperReticle(scale: 1.25, armed: true)
        let side = max(reticle.bounds.width, reticle.bounds.height) + 40   // room for the pop + shadow
        let frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        reticle.position = CGPoint(x: side / 2, y: side / 2)
        view.layer?.addSublayer(reticle)

        panel.contentView = view
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        activePanels.append(panel)

        // Snap in from slightly too big — the reticle lands on the spot rather
        // than growing onto it.
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.45
        pop.toValue = 1.0
        pop.duration = 0.22
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        reticle.add(pop, forKey: "pop")

        // There from the first frame at 80% — a mark that fades *in* asks to be
        // watched arriving; this one is already there when you look. The only
        // fade is the last quarter, where it leaves.
        let life = CAKeyframeAnimation(keyPath: "opacity")
        life.values = [0.8, 0.8, 0.0]
        life.keyTimes = [0.0, 0.75, 1.0]
        life.duration = duration
        life.fillMode = .forwards
        life.isRemovedOnCompletion = false
        view.layer?.add(life, forKey: "life")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
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

    // Cache the tinted glyph per color (the camera silhouette is recomputed only if the
    // border color changes — in practice it's always systemYellow for screenshots).
    private static var glyphCache: [String: NSImage] = [:]

    /// Loads `camera_glyph.png` (black outline on white) and recolors it so white → fully
    /// transparent and black → `tint`, with anti-aliased edges preserved as partial alpha.
    private static func tintedCameraGlyph(tint: NSColor) -> NSImage? {
        let key = tint.usingColorSpace(.deviceRGB)?.description ?? tint.description
        if let cached = glyphCache[key] { return cached }

        guard let url = Bundle.module.url(forResource: "camera_glyph", withExtension: "png", subdirectory: "Resources"),
              let src = NSImage(contentsOf: url),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = cg.width, height = cg.height
        let bytesPerRow = width * 4
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }

        let rgb = tint.usingColorSpace(.deviceRGB) ?? tint
        let tr = rgb.redComponent, tg = rgb.greenComponent, tb = rgb.blueComponent
        let ptr = data.bindMemory(to: UInt8.self, capacity: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                // Source is opaque; map luminance → inverse alpha (black→1, white→0).
                let lum = (Double(ptr[i]) + Double(ptr[i + 1]) + Double(ptr[i + 2])) / (3.0 * 255.0)
                let a = 1.0 - lum
                // premultipliedLast: store tint × alpha.
                ptr[i]     = UInt8((tr * a) * 255.0)
                ptr[i + 1] = UInt8((tg * a) * 255.0)
                ptr[i + 2] = UInt8((tb * a) * 255.0)
                ptr[i + 3] = UInt8(a * 255.0)
            }
        }

        guard let out = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: out, size: NSSize(width: width, height: height))
        glyphCache[key] = image
        return image
    }
}
