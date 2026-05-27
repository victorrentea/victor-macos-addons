import Cocoa

/// Unified bottom-left "pill" used by every banner in the addon
/// (status, silent-mic warning, transcription countdown, prompt-capture).
///
/// Renders a floating NSPanel on every connected screen, flush to the
/// bottom-left corner. The background is an NSVisualEffectView (glass)
/// with a configurable color tint on top — defaults to translucent gray;
/// callers can pass any NSColor (e.g. red for an urgent countdown).
///
/// Hover support is opt-in at construction time (`hoverable: true`). When
/// enabled, the panel accepts mouse events and an NSTrackingArea fires
/// `onHover` the first time the cursor enters on any screen.
///
/// The state-machine logic (presence-gating, countdown ticks, snooze,
/// auto-dismiss) lives in the caller. This class is rendering only.
final class BottomLeftBanner {
    enum Style {
        static let fontSize: CGFloat = 36
        static let leftPadding: CGFloat = 20
        static let rightPadding: CGFloat = 12
        static let textRenderHeight: CGFloat = 50
        static let boxWidth: CGFloat = 480
        static let boxHeight: CGFloat = 80
        static let defaultBackground: NSColor = NSColor.gray.withAlphaComponent(0.6)
        static let textColor: NSColor = .white
        static func defaultFont() -> NSFont {
            NSFont.boldSystemFont(ofSize: fontSize)
        }
    }

    private let screensProvider: () -> [NSScreen]
    private let hoverable: Bool

    private struct PanelEntry {
        let panel: NSPanel
        let tint: NSView
        let label: NSTextField
    }
    private var panels: [PanelEntry] = []

    /// Fires the first time the cursor enters the banner on any screen,
    /// per `show()` invocation. Only meaningful when `hoverable: true`.
    var onHover: (() -> Void)?
    private var hoverFired = false

    init(screensProvider: @escaping () -> [NSScreen], hoverable: Bool = false) {
        self.screensProvider = screensProvider
        self.hoverable = hoverable
    }

    var isVisible: Bool { !panels.isEmpty }

    /// Show the banner with `text` and `backgroundColor`. Replaces any
    /// existing visible content (text + color updated in place; no fade-out
    /// flicker). Fades in over 0.3s when first appearing.
    func show(text: String,
              backgroundColor: NSColor = Style.defaultBackground,
              font: NSFont = Style.defaultFont(),
              boxWidth: CGFloat = Style.boxWidth) {
        if isVisible {
            updateText(text)
            updateBackgroundColor(backgroundColor)
            return
        }
        hoverFired = false
        for screen in screensProvider() {
            panels.append(buildPanel(on: screen,
                                     text: text,
                                     bg: backgroundColor,
                                     font: font,
                                     width: boxWidth))
        }
        for entry in panels {
            entry.panel.alphaValue = 0
            entry.panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            for entry in panels { entry.panel.animator().alphaValue = 1 }
        }
    }

    func updateText(_ text: String) {
        for entry in panels { entry.label.stringValue = text }
    }

    /// Update the gray-tint color over the glass. When `animated`, the
    /// transition runs as an explicit CABasicAnimation of duration `duration`.
    func updateBackgroundColor(_ color: NSColor,
                               animated: Bool = false,
                               duration: TimeInterval = 0.3) {
        let cg = color.cgColor
        for entry in panels {
            guard let layer = entry.tint.layer else { continue }
            if animated {
                let anim = CABasicAnimation(keyPath: "backgroundColor")
                anim.fromValue = layer.backgroundColor
                anim.toValue = cg
                anim.duration = duration
                anim.timingFunction = CAMediaTimingFunction(name: .linear)
                anim.fillMode = .forwards
                layer.add(anim, forKey: "tintColor")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = cg
            CATransaction.commit()
        }
    }

    func dismiss(animated: Bool = true) {
        guard isVisible else { return }
        let toRemove = panels
        panels.removeAll()
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                for entry in toRemove { entry.panel.animator().alphaValue = 0 }
            }, completionHandler: {
                for entry in toRemove { entry.panel.orderOut(nil) }
            })
        } else {
            for entry in toRemove { entry.panel.orderOut(nil) }
        }
    }

    fileprivate func handleHover() {
        guard !hoverFired else { return }
        hoverFired = true
        onHover?()
    }

    private func buildPanel(on screen: NSScreen,
                            text: String,
                            bg: NSColor,
                            font: NSFont,
                            width: CGFloat) -> PanelEntry {
        let frame = screen.frame
        let rect = NSRect(x: frame.minX, y: frame.minY, width: width, height: Style.boxHeight)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = !hoverable

        let content: NSView
        if hoverable {
            let hover = HoverView(frame: NSRect(origin: .zero, size: rect.size))
            hover.banner = self
            content = hover
        } else {
            content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        }
        content.wantsLayer = true

        let effect = NSVisualEffectView(frame: content.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        content.addSubview(effect)

        let tint = NSView(frame: content.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = bg.cgColor
        content.addSubview(tint)

        let textWidth = width - Style.leftPadding - Style.rightPadding
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = Style.textColor
        label.alignment = .left
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: Style.leftPadding,
            y: (Style.boxHeight - Style.textRenderHeight) / 2,
            width: textWidth,
            height: Style.textRenderHeight
        )
        label.autoresizingMask = [.width]
        content.addSubview(label)

        panel.contentView = content
        return PanelEntry(panel: panel, tint: tint, label: label)
    }
}

private final class HoverView: NSView {
    weak var banner: BottomLeftBanner?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with _: NSEvent) {
        banner?.handleHover()
    }
}
