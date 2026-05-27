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

    private static let width: CGFloat = 640
    private static let height: CGFloat = 80
    private static let fontSize: CGFloat = 36
    private static let leftPadding: CGFloat = 20
    private static let rightPadding: CGFloat = 12

    init(screensProvider: @escaping () -> [NSScreen]) {
        self.screensProvider = screensProvider
    }

    /// Show the banner on every screen. Replaces any currently visible banner.
    func show(text: String, id: String, visibleDuration: TimeInterval = 20.0) {
        dismiss(notifying: false)
        pendingId = id
        let display = Self.formatLabel(from: text)
        for screen in screensProvider() {
            panels.append(makePanel(on: screen, labelText: display))
        }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: visibleDuration, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }

    private static func formatLabel(from text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let head = collapsed.prefix(20)
        return "Send? - \(head)"
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

    private func makePanel(on screen: NSScreen, labelText: String) -> NSPanel {
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

        // Glass background (NSVisualEffectView, hudWindow material).
        let effect = NSVisualEffectView(frame: hover.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        hover.addSubview(effect)

        // Gray tint over the glass for the requested "gray translucent" feel,
        // matched to StatusBannerStyle's 0.6 alpha.
        let tint = NSView(frame: hover.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.6).cgColor
        hover.addSubview(tint)

        let textWidth = Self.width - Self.leftPadding - Self.rightPadding
        let label = NSTextField(labelWithString: labelText)
        label.font = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .bold)
        label.textColor = .white
        label.alignment = .left
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(
            x: Self.leftPadding,
            y: (Self.height - 50) / 2,
            width: textWidth,
            height: 50
        )
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
