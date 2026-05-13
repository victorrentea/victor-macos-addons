import AppKit
import CoreImage
import Foundation

/// Banner that displays participant join URL at top of screen.
/// Stays visible while mouse hovers; starts 30s countdown on mouse-out, then 3s fade.
class JoinLinkBanner: NSPanel {
    private let urlLabel: NSTextField
    private var fadeTimer: Timer?
    private var mouseCheckTimer: Timer?
    private var mouseWasInside = false
    private var bannerShowing: Bool = false

    private let targetScreen: NSScreen
    private let bannerHeight: CGFloat = 120
    private let menuBarHeight: CGFloat = 25
    private let horizontalPadding: CGFloat = 48

    // QR code panel
    private var qrPanel: NSPanel?
    private var qrImageView: NSImageView?

    // Progress bar (yellow, full-width, shrinks over `progressDuration`).
    // Sits directly below the banner; click dismisses, hover resets.
    private var progressPanel: ProgressBarPanel?
    private let progressDuration: TimeInterval = 30.0
    private let progressBarHeight: CGFloat = 5.0
    private var progressExpiresAt: Date?
    private var progressTickTimer: Timer?

    init(screen: NSScreen) {
        self.targetScreen = screen

        urlLabel = NSTextField(frame: .zero)

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true  // clicks pass through; we poll for hover

        urlLabel.isBordered = false
        urlLabel.isEditable = false
        urlLabel.isSelectable = false
        urlLabel.drawsBackground = false
        urlLabel.alignment = .center
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.allowsEditingTextAttributes = true

        self.contentView?.addSubview(urlLabel)

        setupQRPanel()
        setupProgressPanel()
    }

    private func setupProgressPanel() {
        let panel = ProgressBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: targetScreen.frame.width, height: progressBarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.onClick = { [weak self] in self?.hide() }
        progressPanel = panel
    }

    // MARK: - QR Panel setup

    private func setupQRPanel() {
        let qrSize = targetScreen.frame.height * 0.30
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 1.0

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: qrSize, height: qrSize))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView?.addSubview(imageView)

        // Position: bottom-right of screen
        let x = targetScreen.frame.origin.x + targetScreen.frame.width - qrSize - 20
        let y = targetScreen.frame.origin.y + 20
        panel.setFrame(NSRect(x: x, y: y, width: qrSize, height: qrSize), display: false)

        self.qrPanel = panel
        self.qrImageView = imageView
    }

    // MARK: - Public API

    func show(url: String) {
        let trimmedUrl = url.trimmingCharacters(in: .whitespaces)
        let maxWidth = targetScreen.frame.width - horizontalPadding * 2

        // Start at default font size; shrink if URL is too wide to fit
        var fontSize: CGFloat = 76
        urlLabel.attributedStringValue = buildAttributedString(url: trimmedUrl, fontSize: fontSize)
        urlLabel.sizeToFit()
        if urlLabel.frame.width > maxWidth {
            fontSize = max(24, floor(fontSize * maxWidth / urlLabel.frame.width))
            urlLabel.attributedStringValue = buildAttributedString(url: trimmedUrl, fontSize: fontSize)
            urlLabel.sizeToFit()
        }

        let fittedWidth = ceil(urlLabel.frame.width)
        let bannerWidth = min(fittedWidth + horizontalPadding * 2, targetScreen.frame.width)
        let bannerX = targetScreen.frame.origin.x + (targetScreen.frame.width - bannerWidth) / 2
        let bannerY = targetScreen.frame.origin.y + targetScreen.frame.height - menuBarHeight - bannerHeight

        let frame = NSRect(x: bannerX, y: bannerY, width: bannerWidth, height: bannerHeight)
        self.setFrame(frame, display: false)

        // Center label vertically within banner
        let textHeight = ceil(urlLabel.frame.height)
        let labelY = (bannerHeight - textHeight) / 2
        urlLabel.frame = NSRect(x: horizontalPadding, y: labelY, width: fittedWidth, height: textHeight)

        self.alphaValue = 1.0
        self.orderFrontRegardless()
        bannerShowing = true
        mouseWasInside = false

        fadeTimer?.invalidate()
        fadeTimer = nil

        // Show QR code
        showQR(for: trimmedUrl)

        // Position + show progress bar just below banner.
        positionProgressPanel(belowBannerY: bannerY)
        progressPanel?.alphaValue = 1.0
        progressPanel?.orderFrontRegardless()

        startMousePolling()

        // Always start the countdown — hover will pause/reset it.
        scheduleHide()
    }

    private func positionProgressPanel(belowBannerY bannerY: CGFloat) {
        guard let panel = progressPanel else { return }
        let y = bannerY - progressBarHeight
        let frame = NSRect(
            x: targetScreen.frame.origin.x,
            y: y,
            width: targetScreen.frame.width,
            height: progressBarHeight
        )
        panel.setFrame(frame, display: false)
        panel.setFullWidth(screenWidth: targetScreen.frame.width)
    }

    func hide() {
        stopAll()
        self.alphaValue = 0.0
        bannerShowing = false
        self.orderOut(nil)
        hideQR()
        progressPanel?.alphaValue = 0.0
        progressPanel?.orderOut(nil)
    }

    var bannerIsVisible: Bool { bannerShowing }

    // MARK: - QR code generation and display

    private func showQR(for url: String) {
        guard let qrPanel = qrPanel, let qrImageView = qrImageView else { return }

        // Prepend https:// for the QR code so phones can open it directly
        let fullUrl = url.hasPrefix("http") ? url : "https://\(url)"
        if let qrImage = generateQRCode(from: fullUrl) {
            qrImageView.image = qrImage
        }
        qrPanel.alphaValue = 1.0
        qrPanel.orderFrontRegardless()
    }

    private func hideQR() {
        qrPanel?.alphaValue = 0.0
        qrPanel?.orderOut(nil)
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up the QR code (it's tiny by default)
        let scale = 20.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = ciImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    // MARK: - Mouse polling (banner keeps ignoresMouseEvents = true so clicks pass through)

    private func startMousePolling() {
        mouseCheckTimer?.invalidate()
        mouseCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkMouse()
        }
    }

    private func checkMouse() {
        guard bannerShowing else { return }
        let mouse = NSEvent.mouseLocation
        let bannerHit = self.frame.contains(mouse)
        let barHit = progressPanel?.frame.contains(mouse) ?? false
        let inside = bannerHit || barHit

        if inside && !mouseWasInside {
            // Mouse entered — pause countdown and restore full progress bar.
            mouseWasInside = true
            fadeTimer?.invalidate()
            fadeTimer = nil
            stopProgressTick()
            progressExpiresAt = nil
            progressPanel?.setFullWidth(screenWidth: targetScreen.frame.width)
            self.alphaValue = 1.0
        } else if !inside && mouseWasInside {
            // Mouse exited — restart the 30s countdown from full.
            mouseWasInside = false
            scheduleHide()
        }
    }

    // MARK: - Hide sequence

    private func scheduleHide() {
        fadeTimer?.invalidate()
        // Drive both the visible progress bar and the eventual fade from a single
        // expiration timestamp. When the bar hits zero, kick off the existing 3s fade.
        progressExpiresAt = Date().addingTimeInterval(progressDuration)
        startProgressTick()
    }

    private func startProgressTick() {
        stopProgressTick()
        // 30 fps is enough for a smooth shrink without burning cycles.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTickTimer = timer
        tickProgress()
    }

    private func stopProgressTick() {
        progressTickTimer?.invalidate()
        progressTickTimer = nil
    }

    private func tickProgress() {
        guard let expiresAt = progressExpiresAt else { return }
        let remaining = expiresAt.timeIntervalSinceNow
        let ratio = max(0, min(1, remaining / progressDuration))
        progressPanel?.setProgress(CGFloat(ratio), screenWidth: targetScreen.frame.width)
        if remaining <= 0 {
            stopProgressTick()
            progressExpiresAt = nil
            startFadeOut()
        }
    }

    private func startFadeOut() {
        stopMousePolling()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 3.0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
            self.qrPanel?.animator().alphaValue = 0.0
            self.progressPanel?.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.bannerShowing = false
            self?.orderOut(nil)
            self?.qrPanel?.orderOut(nil)
            self?.progressPanel?.orderOut(nil)
        })
    }

    private func stopAll() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        stopMousePolling()
        stopProgressTick()
        progressExpiresAt = nil
    }

    private func stopMousePolling() {
        mouseCheckTimer?.invalidate()
        mouseCheckTimer = nil
    }

    // MARK: - Attributed string

    private func buildAttributedString(url: String, fontSize: CGFloat = 76) -> NSAttributedString {
        let parts = url.split(separator: "/")
        let result = NSMutableAttributedString()
        if parts.count > 1 {
            let domainPart = parts.dropLast().joined(separator: "/")
            result.append(NSAttributedString(
                string: domainPart + "/",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            ))
            result.append(NSAttributedString(
                string: String(parts.last!),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: NSColor.yellow
                ]
            ))
        } else {
            result.append(NSAttributedString(
                string: url,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            ))
        }
        return result
    }
}

/// Yellow progress bar that visualizes the join-link auto-hide countdown.
/// The bar shrinks centered as time runs out; the underlying panel still spans
/// the full screen width so clicks anywhere along the row dismiss the link.
final class ProgressBarPanel: NSPanel {
    var onClick: (() -> Void)?
    private let fillView: NSView

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        fillView = NSView(frame: contentRect)
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        let host = NSView(frame: contentRect)
        host.wantsLayer = true
        // Faint backing so the clickable strip is still hittable when the
        // visible bar has shrunk to zero — without it, AppKit ignores clicks
        // on the transparent regions.
        host.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        self.contentView = host

        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor.systemYellow.cgColor
        host.addSubview(fillView)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        host.addGestureRecognizer(click)
    }

    func setFullWidth(screenWidth: CGFloat) {
        setProgress(1.0, screenWidth: screenWidth)
    }

    func setProgress(_ ratio: CGFloat, screenWidth: CGFloat) {
        let clamped = max(0, min(1, ratio))
        let width = screenWidth * clamped
        let x = (screenWidth - width) / 2
        fillView.frame = NSRect(x: x, y: 0, width: width, height: fillView.superview?.bounds.height ?? frame.height)
    }

    @objc private func handleClick() {
        onClick?()
    }
}
