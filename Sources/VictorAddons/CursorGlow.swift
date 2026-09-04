import AppKit

/// Persists whether the yellow cursor glow should be on, surviving app restarts.
enum CursorGlowSettings {
    static let enabledKey = "CursorGlow.enabled"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

/// macOS gives no API to re-skin the system pointer bitmap itself (whatever
/// shape it currently is — arrow, I-beam, resize, …), so this fakes a glow by
/// painting a soft yellow halo on a click-through panel that chases
/// `NSEvent.mouseLocation` every frame, the same trick `BusyCursorSpinner`
/// uses for its one-shot busy indicator. Unlike that spinner this one is a
/// toggle meant to stay on indefinitely, so it lives across all
/// spaces/screens and is centered exactly on the hotspot rather than offset
/// beside it.
@MainActor
final class CursorGlow {
    private var panel: NSPanel?
    private var timer: Timer?

    private let diameter: CGFloat = 56

    func start() {
        guard panel == nil else { return }

        let side = diameter
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let glowView = CursorGlowView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        panel.contentView = glowView
        self.panel = panel

        follow()
        panel.orderFrontRegardless()

        // Same 30ms cadence as BusyCursorSpinner — glued to a moving cursor
        // without noticeable lag, at the cost of a window move per tick.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func follow() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x - diameter / 2, y: mouse.y - diameter / 2))
    }
}

/// Draws a radial yellow glow — bright, near-opaque center fading to fully
/// transparent at the edge — so it reads as a halo around whatever cursor
/// shape macOS is currently showing, instead of a flat colored disc.
private final class CursorGlowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = bounds.width / 2

        let colors = [
            NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.2, alpha: 0.85).cgColor,
            NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.2, alpha: 0.0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0.0, 1.0]) else { return }
        context.drawRadialGradient(gradient,
                                    startCenter: center, startRadius: 0,
                                    endCenter: center, endRadius: radius,
                                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}
