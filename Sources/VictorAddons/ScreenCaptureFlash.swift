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

    static func flash(on screen: NSScreen, duration: CFTimeInterval = 1.5, thickness: CGFloat = 30, color: NSColor = .systemYellow) {
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
}
