import AppKit
import Foundation

/// Banner that displays participant join URL at top of screen
/// Auto-hides after 20 seconds with 3 second fade-out animation
class JoinLinkBanner: NSPanel {
    private let urlLabel: NSTextField
    private var fadeTimer: Timer?
    private var bannerShowing: Bool = false

    init(screen: NSScreen) {
        // Position at top of screen, just below menu bar
        let menuBarHeight: CGFloat = 25
        let bannerHeight: CGFloat = 60
        let bannerFrame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - menuBarHeight - bannerHeight,
            width: screen.frame.width,
            height: bannerHeight
        )

        // Create label with monospaced font before super.init
        urlLabel = NSTextField(frame: NSRect(
            x: 20,
            y: 0,
            width: bannerFrame.width - 40,
            height: bannerHeight
        ))

        // Create panel with semi-transparent background
        super.init(
            contentRect: bannerFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true

        // Configure label
        urlLabel.isBordered = false
        urlLabel.isEditable = false
        urlLabel.isSelectable = false
        urlLabel.drawsBackground = false
        urlLabel.textColor = .white
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 28, weight: .medium)
        urlLabel.alignment = .center
        urlLabel.lineBreakMode = .byTruncatingMiddle

        self.contentView?.addSubview(urlLabel)
    }

    /// Show banner with URL and start auto-hide timer
    func show(url: String) {
        urlLabel.stringValue = url
        self.alphaValue = 1.0
        self.orderFrontRegardless()
        bannerShowing = true

        // Cancel any existing timer
        fadeTimer?.invalidate()

        // Schedule fade-out to start at 17 seconds
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 17.0, repeats: false) { [weak self] _ in
            self?.startFadeOut()
        }
    }

    /// Start fade-out animation (3 seconds)
    private func startFadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 3.0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.bannerShowing = false
            self?.orderOut(nil)
        })
    }

    /// Hide banner immediately without animation
    func hide() {
        // Cancel timers
        fadeTimer?.invalidate()
        fadeTimer = nil

        // Stop any running animations
        NSAnimationContext.current.duration = 0
        self.alphaValue = 0.0

        // Remove from screen
        bannerShowing = false
        self.orderOut(nil)
    }

    /// Check if banner is currently visible
    var bannerIsVisible: Bool {
        return bannerShowing
    }
}
