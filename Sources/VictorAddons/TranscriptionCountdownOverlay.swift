import Cocoa

/// Displays a countdown overlay at 6pm before auto-stopping transcription.
/// Shows countdown (5, 4, 3, 2, 1), detects hover to cancel, shows "Ended" state.
final class TranscriptionCountdownOverlay {
    private weak var overlayPanel: OverlayPanel?
    private var countdownLayer: CATextLayer?
    private var backgroundLayer: CALayer?
    private var countdownTimer: Timer?
    private var mouseCheckTimer: Timer?
    private var remainingSeconds = 5
    private var isInEndedState = false
    private var mouseWasInside = false
    private var onContinueCallback: (() -> Void)?
    private var onStopCallback: (() -> Void)?

    private let fontSize: CGFloat = 40
    private let padding: CGFloat = 24
    private let cornerRadius: CGFloat = 12

    init(overlayPanel: OverlayPanel?) {
        self.overlayPanel = overlayPanel
    }

    /// Starts the 5-second countdown before stopping transcription.
    /// - Parameters:
    ///   - onContinue: Called if user hovers during countdown
    ///   - onStop: Called if countdown finishes without hover
    func startCountdown(onContinue: @escaping () -> Void, onStop: @escaping () -> Void) {
        self.onContinueCallback = onContinue
        self.onStopCallback = onStop
        remainingSeconds = 5
        isInEndedState = false

        overlayInfo("Starting 6pm transcription countdown")

        createOverlayLayers()
        updateCountdownText()
        startCountdownTimer()
        startMousePolling()
    }

    private func createOverlayLayers() {
        guard let overlayView = overlayPanel?.contentView else { return }

        // Ensure layer-backed
        overlayView.wantsLayer = true
        guard let hostLayer = overlayView.layer else { return }

        // Position in bottom-left with padding
        let screen = NSScreen.main ?? NSScreen.screens.first!

        let textSize: CGFloat = 180
        let totalWidth: CGFloat = textSize + padding * 2
        let totalHeight: CGFloat = 80 + padding * 2

        let xPos: CGFloat = padding
        let yPos: CGFloat = padding

        // Background layer (gray translucent)
        let bg = CALayer()
        bg.frame = CGRect(x: xPos, y: yPos, width: totalWidth, height: totalHeight)
        bg.backgroundColor = NSColor.gray.withAlphaComponent(0.6).cgColor
        bg.cornerRadius = cornerRadius
        bg.opacity = 0
        hostLayer.addSublayer(bg)
        backgroundLayer = bg

        // Text layer for countdown
        let text = CATextLayer()
        text.frame = CGRect(x: xPos + padding, y: yPos + padding / 2, width: textSize, height: 80)
        text.fontSize = fontSize
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .left
        text.contentsScale = screen.backingScaleFactor
        text.opacity = 0
        hostLayer.addSublayer(text)
        countdownLayer = text

        // Fade in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            bg.opacity = 1
            text.opacity = 1
        }
    }

    private func updateCountdownText() {
        let text: String
        if isInEndedState {
            text = "Ended"
        } else {
            text = "ending in \(remainingSeconds)…"
        }
        countdownLayer?.string = text
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.countdownTick()
        }
    }

    private func countdownTick() {
        remainingSeconds -= 1

        if remainingSeconds > 0 {
            updateCountdownText()
        } else {
            // Countdown finished
            enterEndedState()
        }
    }

    private func enterEndedState() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isInEndedState = true
        updateCountdownText()
        overlayInfo("Countdown reached 0, entering 'Ended' state - waiting for mouse movement")

        // Wait for mouse movement before proceeding
        // The mouseCheckTimer will detect when mouse starts moving
    }

    private var lastMousePosition: NSPoint?
    private var waitingForMovement = false

    private func startMousePolling() {
        mouseCheckTimer?.invalidate()
        mouseCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkMouse()
        }
    }

    private func checkMouse() {
        guard let bg = backgroundLayer else { return }

        // Get global mouse position
        let mousePos = NSEvent.mouseLocation

        // Detect mouse movement in "Ended" state
        if isInEndedState && !waitingForMovement {
            if let last = lastMousePosition, last != mousePos {
                overlayInfo("Mouse movement detected in 'Ended' state")
                waitingForMovement = true
                onMouseMovementDetected()
            }
        }
        lastMousePosition = mousePos

        // Check hover region
        guard let overlayView = overlayPanel?.contentView,
              let window = overlayView.window else { return }

        let localPos = window.convertPoint(fromScreen: mousePos)
        let inside = bg.frame.contains(localPos)

        if inside && !mouseWasInside {
            // Mouse entered hover region
            mouseWasInside = true
            onMouseEnter()
        } else if !inside && mouseWasInside {
            // Mouse exited
            mouseWasInside = false
        }
    }

    private func onMouseEnter() {
        if !isInEndedState && remainingSeconds > 0 {
            // User hovered during countdown → continue transcription silently
            overlayInfo("User hovered during countdown, continuing transcription")
            continueSilently()
        } else if isInEndedState && waitingForMovement {
            // User hovered after movement detected → restart transcription
            overlayInfo("User hovered in 'Ended' state after movement, restarting transcription")
            restartTranscription()
        }
    }

    private func continueSilently() {
        cleanup()
        onContinueCallback?()
    }

    private func restartTranscription() {
        cleanup()
        onContinueCallback?()
    }

    /// Called when mouse movement is detected in "Ended" state
    private func onMouseMovementDetected() {
        // Wait 5 more seconds, then check if hovering
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }

            // Check if mouse is hovering over the countdown area
            if self.mouseWasInside {
                overlayInfo("Mouse hovering after 5s, restarting transcription")
                self.restartTranscription()
            } else {
                overlayInfo("No hover after 5s, stopping transcription")
                self.stopTranscription()
            }
        }
    }

    private func stopTranscription() {
        cleanup()
        onStopCallback?()
    }

    private func cleanup() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        mouseCheckTimer?.invalidate()
        mouseCheckTimer = nil

        // Fade out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            backgroundLayer?.opacity = 0
            countdownLayer?.opacity = 0
        }, completionHandler: { [weak self] in
            self?.backgroundLayer?.removeFromSuperlayer()
            self?.countdownLayer?.removeFromSuperlayer()
            self?.backgroundLayer = nil
            self?.countdownLayer = nil
        })
    }
}
