import AppKit

/// Bottom-left "Send prompt" banner shown when Claude Code forwards a user
/// prompt via the /training/prompt-capture endpoint. Hovering the banner
/// commits the prompt to session notes; ignoring it for `visibleDuration`
/// drops it silently.
///
/// Mirrored across every connected screen so the user can reach it from any
/// display. Glass background via `NSVisualEffectView` + a thin gray tint on
/// top to match the StatusBanner family of overlays.
final class PromptCaptureBanner {
    private let screensProvider: () -> [NSScreen]
    private var panels: [NSPanel] = []
    private var dismissTimer: Timer?
    private var pendingId: String?

    private static let width: CGFloat = 280
    private static let height: CGFloat = 64

    init(screensProvider: @escaping () -> [NSScreen]) {
        self.screensProvider = screensProvider
    }

    /// Show the banner on every screen. Replaces any currently visible banner.
    func show(text _: String, id: String, visibleDuration: TimeInterval = 20.0) {
        dismiss(notifying: false)
        pendingId = id
        for screen in screensProvider() {
            panels.append(makePanel(on: screen))
        }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: visibleDuration, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }

    private func handleTimeout() {
        if let id = pendingId {
            SessionNotesAppender.discardPendingPrompt(id: id)
        }
        dismiss(notifying: false)
    }

    /// Called by the hover view when the user moves the cursor onto the banner.
    fileprivate func handleHover() {
        if let id = pendingId {
            SessionNotesAppender.acceptPendingPrompt(id: id)
        }
        dismiss(notifying: false)
    }

    private func dismiss(notifying _: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        pendingId = nil
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        let frame = screen.frame
        let rect = NSRect(x: frame.minX, y: frame.minY, width: Self.width, height: Self.height)
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
        panel.ignoresMouseEvents = false

        let hover = HoverView(frame: NSRect(origin: .zero, size: rect.size))
        hover.banner = self
        hover.wantsLayer = true

        // Glass — NSVisualEffectView with hudWindow material gives the
        // translucent gray look matching macOS HUDs.
        let effect = NSVisualEffectView(frame: hover.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        // Round only the top-right corner since the banner is flush to the
        // bottom-left screen corner.
        effect.layer?.cornerRadius = 10
        effect.layer?.maskedCorners = [.layerMaxXMaxYCorner]
        hover.addSubview(effect)

        // Extra gray tint for a slightly stronger "gray translucent" feel.
        let tint = NSView(frame: hover.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.25).cgColor
        tint.layer?.cornerRadius = 10
        tint.layer?.maskedCorners = [.layerMaxXMaxYCorner]
        hover.addSubview(tint)

        let label = NSTextField(labelWithString: "Send prompt")
        label.font = NSFont.boldSystemFont(ofSize: 22)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.frame = NSRect(x: 0, y: (Self.height - 28) / 2, width: Self.width, height: 28)
        label.autoresizingMask = [.width]
        hover.addSubview(label)

        panel.contentView = hover
        panel.orderFrontRegardless()
        return panel
    }
}

private final class HoverView: NSView {
    weak var banner: PromptCaptureBanner?

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
