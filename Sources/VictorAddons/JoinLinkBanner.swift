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
        let attributed = buildAttributedString(url: trimmedUrl)
        urlLabel.attributedStringValue = attributed

        // Measure text to size banner — use sizeToFit for accurate width
        urlLabel.sizeToFit()
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

        startMousePolling()

        // If mouse is already outside, begin countdown immediately
        if !frame.contains(NSEvent.mouseLocation) {
            scheduleHide()
        }
    }

    func hide() {
        stopAll()
        self.alphaValue = 0.0
        bannerShowing = false
        self.orderOut(nil)
        hideQR()
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
        let inside = self.frame.contains(NSEvent.mouseLocation)

        if inside && !mouseWasInside {
            // Mouse entered — cancel any countdown and restore opacity
            mouseWasInside = true
            fadeTimer?.invalidate()
            fadeTimer = nil
            self.alphaValue = 1.0
        } else if !inside && mouseWasInside {
            // Mouse exited — start 30s countdown
            mouseWasInside = false
            scheduleHide()
        }
    }

    // MARK: - Hide sequence

    private func scheduleHide() {
        fadeTimer?.invalidate()
        // 30s visible, then 3s fade = schedule fade at 27s
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 27.0, repeats: false) { [weak self] _ in
            self?.startFadeOut()
        }
    }

    private func startFadeOut() {
        stopMousePolling()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 3.0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
            self.qrPanel?.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.bannerShowing = false
            self?.orderOut(nil)
            self?.qrPanel?.orderOut(nil)
        })
    }

    private func stopAll() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        stopMousePolling()
    }

    private func stopMousePolling() {
        mouseCheckTimer?.invalidate()
        mouseCheckTimer = nil
    }

    // MARK: - Attributed string

    private func buildAttributedString(url: String) -> NSAttributedString {
        let parts = url.split(separator: "/")
        let result = NSMutableAttributedString()
        if parts.count > 1 {
            let domainPart = parts.dropLast().joined(separator: "/")
            result.append(NSAttributedString(
                string: domainPart + "/",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 76, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            ))
            result.append(NSAttributedString(
                string: String(parts.last!),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 76, weight: .bold),
                    .foregroundColor: NSColor.yellow
                ]
            ))
        } else {
            result.append(NSAttributedString(
                string: url,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 76, weight: .medium),
                    .foregroundColor: NSColor.white
                ]
            ))
        }
        return result
    }
}
