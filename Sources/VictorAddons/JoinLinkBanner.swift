import AppKit
import Foundation

/// Banner that displays participant join URL at top of screen
/// Auto-hides after 20 seconds with 3 second fade-out animation
class JoinLinkBanner: NSPanel {
    private let urlLabel: NSTextField
    private var fadeTimer: Timer?
    private var shimmerTimer: Timer?
    private var bannerShowing: Bool = false
    private var shimmerOffset: CGFloat = 0

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

        // Configure label (3x larger font: 28 * 3 = 84)
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
            // Domain part in white
            let domainPart = parts.dropLast().joined(separator: "/")
            let domain = NSAttributedString(
                string: domainPart + "/",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 84, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            )
            attributedString.append(domain)

            // Session code in yellow and bold
            let sessionCode = String(parts.last!)
            let code = NSAttributedString(
                string: sessionCode,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 84, weight: .bold),
                    .foregroundColor: NSColor.yellow
                ]
            )
            attributedString.append(code)
        } else {
            // Fallback if no "/" found
            let fallback = NSAttributedString(
                string: url,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 84, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            )
            attributedString.append(fallback)
        }

        urlLabel.attributedStringValue = attributedString
        self.alphaValue = 1.0
        self.orderFrontRegardless()
        bannerShowing = true

        // Cancel any existing timers
        fadeTimer?.invalidate()
        shimmerTimer?.invalidate()

        // Start shimmer animation
        startShimmerAnimation()

        // Schedule fade-out to start at 17 seconds
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 17.0, repeats: false) { [weak self] _ in
            self?.startFadeOut()
        }
    }

    /// Shimmer animation effect - creates a subtle shine sweep
    private func startShimmerAnimation() {
        shimmerOffset = 0
        shimmerTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.bannerShowing else { return }

            self.shimmerOffset += 0.03
            if self.shimmerOffset > 1.0 {
                self.shimmerOffset = -0.5
            }

            self.updateShimmer()
        }
    }

    /// Update shimmer effect by adjusting text alpha
    private func updateShimmer() {
        guard let currentString = urlLabel.attributedStringValue.mutableCopy() as? NSMutableAttributedString else { return }

        let fullRange = NSRange(location: 0, length: currentString.length)
        let shimmerPosition = shimmerOffset * CGFloat(currentString.length)

        currentString.enumerateAttributes(in: fullRange) { attrs, range, _ in
            let distance = abs(CGFloat(range.location) - shimmerPosition)
            let maxDistance: CGFloat = 10
            let brightness = max(0, 1.0 - (distance / maxDistance))

            if let baseColor = attrs[.foregroundColor] as? NSColor {
                let shimmerColor = baseColor.blended(withFraction: brightness * 0.4, of: .white) ?? baseColor
                currentString.addAttribute(.foregroundColor, value: shimmerColor, range: range)
            }
        }

        urlLabel.attributedStringValue = currentString
    }

    /// Start fade-out animation (3 seconds)
    private func startFadeOut() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil

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
        shimmerTimer?.invalidate()
        shimmerTimer = nil

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
