import AppKit
import Foundation

/// Banner that displays participant join URL at top of screen
/// Auto-hides after 30 seconds with 3 second fade-out animation
class JoinLinkBanner: NSPanel {
    private let urlLabel: NSTextField
    private var fadeTimer: Timer?
    private var bannerShowing: Bool = false

    init(screen: NSScreen) {
        // Position at top of screen, just below menu bar (larger height for bigger text)
        let menuBarHeight: CGFloat = 25
        let bannerHeight: CGFloat = 120
        let bannerFrame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - menuBarHeight - bannerHeight,
            width: screen.frame.width,
            height: bannerHeight
        )

        // Create label with monospaced font before super.init - centered with full width
        urlLabel = NSTextField(frame: NSRect(
            x: 0,
            y: 0,
            width: bannerFrame.width,
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

        // Configure label (84pt - 10% = 75.6pt ≈ 76pt)
        urlLabel.isBordered = false
        urlLabel.isEditable = false
        urlLabel.isSelectable = false
        urlLabel.drawsBackground = false
        urlLabel.alignment = .center
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.allowsEditingTextAttributes = true

        self.contentView?.addSubview(urlLabel)
    }

    /// Show banner with URL and start auto-hide timer
    func show(url: String) {
        // Split URL at last "/" to highlight session code
        let parts = url.split(separator: "/")
        let attributedString = NSMutableAttributedString()

        if parts.count > 1 {
            // Domain part in white (76pt font)
            let domainPart = parts.dropLast().joined(separator: "/")
            let domain = NSAttributedString(
                string: domainPart + "/",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 76, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            )
            attributedString.append(domain)

            // Session code in yellow and bold (76pt font)
            let sessionCode = String(parts.last!)
            let code = NSAttributedString(
                string: sessionCode,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 76, weight: .bold),
                    .foregroundColor: NSColor.yellow
                ]
            )
            attributedString.append(code)
        } else {
            // Fallback if no "/" found (76pt font)
            let fallback = NSAttributedString(
                string: url,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 76, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            )
            attributedString.append(fallback)
        }

        urlLabel.attributedStringValue = attributedString
        self.alphaValue = 1.0
        self.orderFrontRegardless()
        bannerShowing = true

        // Cancel any existing timer
        fadeTimer?.invalidate()

        // Schedule fade-out to start at 27 seconds (30 total - 3 seconds fade)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 27.0, repeats: false) { [weak self] _ in
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
        // Cancel timer
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
