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

    static func flash(on screen: NSScreen, duration: CFTimeInterval = 1.5, thickness: CGFloat = 30, color: NSColor = .systemYellow, showCameraGlyph: Bool = false) {
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

        let solid = color.cgColor
        let clear = color.withAlphaComponent(0).cgColor

        // Top edge: solid at outer (top) → clear at inner (bottom)
        let top = CAGradientLayer()
        top.frame = CGRect(x: 0, y: size.height - thickness, width: size.width, height: thickness)
        top.colors = [solid, clear]
        top.startPoint = CGPoint(x: 0.5, y: 1.0)
        top.endPoint = CGPoint(x: 0.5, y: 0.0)

        // Bottom edge: solid at outer (bottom) → clear at inner (top)
        let bottom = CAGradientLayer()
        bottom.frame = CGRect(x: 0, y: 0, width: size.width, height: thickness)
        bottom.colors = [solid, clear]
        bottom.startPoint = CGPoint(x: 0.5, y: 0.0)
        bottom.endPoint = CGPoint(x: 0.5, y: 1.0)

        // Left edge: solid at outer (left) → clear at inner (right)
        let left = CAGradientLayer()
        left.frame = CGRect(x: 0, y: 0, width: thickness, height: size.height)
        left.colors = [solid, clear]
        left.startPoint = CGPoint(x: 0.0, y: 0.5)
        left.endPoint = CGPoint(x: 1.0, y: 0.5)

        // Right edge: solid at outer (right) → clear at inner (left)
        let right = CAGradientLayer()
        right.frame = CGRect(x: size.width - thickness, y: 0, width: thickness, height: size.height)
        right.colors = [solid, clear]
        right.startPoint = CGPoint(x: 1.0, y: 0.5)
        right.endPoint = CGPoint(x: 0.0, y: 0.5)

        for edge in [top, bottom, left, right] {
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
