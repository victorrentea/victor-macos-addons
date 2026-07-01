import AppKit

/// Prominent, centered "📸 Group Photo" reminder shown at the start of a
/// qualifying break (lunch, or an afternoon break ≥ 10 min).
///
/// Unlike a macOS notification, this is the app drawing its own always-on-top
/// panel — so it shows even while PowerPoint is presenting fullscreen / mirroring
/// to a projector, which makes macOS suppress normal notification banners
/// silently into Notification Center. Fades in, holds, then fades out; a click
/// dismisses it early. Latest-wins: a new `show()` replaces any visible card.
final class GroupPhotoOverlay {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private let screenProvider: () -> NSScreen

    /// How long the card stays fully visible before it fades out.
    private let holdDuration: TimeInterval = 12.0
    private let fadeInDuration: TimeInterval = 0.35
    private let fadeOutDuration: TimeInterval = 0.6

    init(screenProvider: @escaping () -> NSScreen) {
        self.screenProvider = screenProvider
    }

    func show(title: String = "📸 Group Photo",
              subtitle: String = "Let's make some memories? :D") {
        DispatchQueue.main.async { self.present(title: title, subtitle: subtitle) }
    }

    private func present(title: String, subtitle: String) {
        teardown()  // latest-wins

        let screen = screenProvider()
        let cardWidth = min(screen.frame.width * 0.6, 900)
        let cardHeight: CGFloat = 260

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false

        let card = NSView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        card.layer?.cornerRadius = 28
        card.layer?.borderWidth = 2
        card.layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor

        let titleLabel = Self.label(title, size: 68, weight: .bold, color: .white)
        let subtitleLabel = Self.label(subtitle, size: 34, weight: .medium, color: .systemYellow)
        titleLabel.frame = NSRect(x: 0, y: cardHeight * 0.42, width: cardWidth, height: 96)
        subtitleLabel.frame = NSRect(x: 0, y: cardHeight * 0.16, width: cardWidth, height: 52)
        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        card.addGestureRecognizer(click)
        panel.contentView = card

        let x = screen.frame.origin.x + (screen.frame.width - cardWidth) / 2
        let y = screen.frame.origin.y + (screen.frame.height - cardHeight) * 0.62
        panel.setFrame(NSRect(x: x, y: y, width: cardWidth, height: cardHeight), display: false)

        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        self.panel = panel

        NSSound(named: NSSound.Name("Glass"))?.play()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeInDuration
            panel.animator().alphaValue = 1.0
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    @objc private func handleClick() { fadeOut() }

    private func fadeOut() {
        dismissTimer?.invalidate(); dismissTimer = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeOutDuration
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.teardown()
        })
    }

    private func teardown() {
        dismissTimer?.invalidate(); dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.isBezeled = false
        l.drawsBackground = false
        l.isEditable = false
        l.isSelectable = false
        return l
    }
}
