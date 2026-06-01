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
        /// Lower bound so a single glyph (e.g. a lone emoji) never collapses to
        /// a sliver. The box hugs the text above this and caps at `maxWidthFraction`.
        static let minBoxWidth: CGFloat = 80
        /// Hard cap as a fraction of the screen width — past this the text
        /// truncates with an ellipsis instead of the box growing further.
        static let maxWidthFraction: CGFloat = 0.5
        static let boxHeight: CGFloat = 80
        /// No extra tint by default — the NSVisualEffectView glass handles
        /// the gray-translucent look on its own. Callers that need a
        /// specific color (e.g. countdown red) pass their own NSColor.
        static let defaultBackground: NSColor = .clear
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
        /// White overlay above the tint that ramps up during the hover
        /// dwell. Alpha 0 at rest, alpha 1 the instant `onHover` fires.
        let whitenTint: NSView
        let label: NSTextField
        /// Kept so `updateText` can re-measure and resize the box to hug the
        /// new text (still capped at `maxWidthFraction` of this screen).
        let font: NSFont
        let screen: NSScreen
    }
    private var panels: [PanelEntry] = []

    /// Fires once per `show()` after the cursor has *dwelled* inside the
    /// banner for at least `hoverDwellRequiredSamples × hoverDwellInterval`
    /// (0.5s by default). Cursor merely happening to be in the corner when
    /// the banner appears never fires this — NSTrackingArea only kicks in
    /// on a fresh entry, and even then the user must hold the cursor in
    /// place. Only meaningful when `hoverable: true`.
    var onHover: (() -> Void)?
    private var hoverFired = false

    private static let hoverDwellInterval: TimeInterval = 0.1
    private static let hoverDwellRequiredSamples = 10
    private var hoverDwellTimer: Timer?
    private var hoverDwellCount = 0

    /// Final window opacity when visible. Below 1.0 to add an extra layer
    /// of see-through on top of the NSVisualEffectView glass.
    private static let visibleAlpha: CGFloat = 0.75

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
              font: NSFont = Style.defaultFont()) {
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
                                     font: font))
        }
        for entry in panels {
            entry.panel.alphaValue = 0
            entry.panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            for entry in panels { entry.panel.animator().alphaValue = Self.visibleAlpha }
        }
    }

    func updateText(_ text: String) {
        for entry in panels {
            entry.label.stringValue = text
            resize(entry, to: panelWidth(for: text, font: entry.font, screen: entry.screen))
        }
    }

    /// Width that hugs `text` at `font`, floored at `minBoxWidth` and capped at
    /// `maxWidthFraction` of the screen — past the cap the label truncates.
    private func panelWidth(for text: String, font: NSFont, screen: NSScreen) -> CGFloat {
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        let content = ceil(measured) + Style.leftPadding + Style.rightPadding
        let maxWidth = screen.frame.width * Style.maxWidthFraction
        return min(max(content, Style.minBoxWidth), maxWidth)
    }

    /// Resize a panel (anchored bottom-left) and its label to `width` in place.
    private func resize(_ entry: PanelEntry, to width: CGFloat) {
        guard abs(entry.panel.frame.width - width) > 0.5 else { return }
        let f = entry.screen.frame
        entry.panel.setFrame(NSRect(x: f.minX, y: f.minY, width: width, height: Style.boxHeight),
                             display: true)
        entry.label.frame = NSRect(
            x: Style.leftPadding,
            y: (Style.boxHeight - Style.textRenderHeight) / 2,
            width: width - Style.leftPadding - Style.rightPadding,
            height: Style.textRenderHeight
        )
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
        cancelHoverDwell()
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

    fileprivate func startHoverDwell() {
        guard hoverable, !hoverFired, hoverDwellTimer == nil else { return }
        hoverDwellCount = 0
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDwellInterval, repeats: true) { [weak self] _ in
            self?.tickHoverDwell()
        }
    }

    fileprivate func cancelHoverDwell() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
        if hoverDwellCount > 0 {
            hoverDwellCount = 0
            applyWhitenProgress(0)
        }
    }

    private func tickHoverDwell() {
        guard !hoverFired else { cancelHoverDwell(); return }
        if isMouseInsideAnyPanel() {
            hoverDwellCount += 1
            let progress = min(1.0, CGFloat(hoverDwellCount) / CGFloat(Self.hoverDwellRequiredSamples))
            applyWhitenProgress(progress)
            if hoverDwellCount >= Self.hoverDwellRequiredSamples {
                hoverDwellTimer?.invalidate()
                hoverDwellTimer = nil
                fireHover()
            }
        } else if hoverDwellCount > 0 {
            hoverDwellCount = 0
            applyWhitenProgress(0)
        }
    }

    /// Animate the per-panel "whitening" overlay to `alpha`. Linear over
    /// one dwell-tick interval so the ramp feels continuous as the user
    /// holds the cursor in place.
    private func applyWhitenProgress(_ alpha: CGFloat) {
        let cg = NSColor.white.withAlphaComponent(alpha).cgColor
        for entry in panels {
            guard let layer = entry.whitenTint.layer else { continue }
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.backgroundColor
            anim.toValue = cg
            anim.duration = Self.hoverDwellInterval
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(anim, forKey: "whiten")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = cg
            CATransaction.commit()
        }
    }

    private func isMouseInsideAnyPanel() -> Bool {
        let pos = NSEvent.mouseLocation
        for entry in panels where entry.panel.frame.contains(pos) {
            return true
        }
        return false
    }

    private func fireHover() {
        guard !hoverFired else { return }
        hoverFired = true
        onHover?()
    }

    private func buildPanel(on screen: NSScreen,
                            text: String,
                            bg: NSColor,
                            font: NSFont) -> PanelEntry {
        let frame = screen.frame
        let width = panelWidth(for: text, font: font, screen: screen)
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
        effect.isEmphasized = true
        content.addSubview(effect)

        let tint = NSView(frame: content.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = bg.cgColor
        content.addSubview(tint)

        let whitenTint = NSView(frame: content.bounds)
        whitenTint.autoresizingMask = [.width, .height]
        whitenTint.wantsLayer = true
        whitenTint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0).cgColor
        content.addSubview(whitenTint)

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
        return PanelEntry(panel: panel, tint: tint, whitenTint: whitenTint, label: label,
                          font: font, screen: screen)
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
        banner?.startHoverDwell()
    }

    override func mouseExited(with _: NSEvent) {
        banner?.cancelHoverDwell()
    }
}
