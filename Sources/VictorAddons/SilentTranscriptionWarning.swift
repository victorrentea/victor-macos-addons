import Cocoa

/// Periodic "no sound captured" hint while transcription is on.
///
/// Every 5 minutes after transcription starts, if the transcription file
/// has been stale (no new lines for ~3 min as reported by
/// `TranscriptionWatcher`), briefly shows a "😶" gray pill in the
/// bottom-left of every screen for 5 seconds. Hovering the pill snoozes
/// the warning until the next time transcription starts (manual click,
/// 09:00 workday entry, AC resume, or heartbeat-detected restart).
final class SilentTranscriptionWarning {
    private let panelsProvider: () -> [OverlayPanel]

    private struct PanelLayers {
        let panel: OverlayPanel
        let bg: CALayer
        let text: CATextLayer
    }
    private var perScreen: [PanelLayers] = []

    private var checkTimer: Timer?
    private var visibleTimer: Timer?
    private var hoverPollTimer: Timer?

    private var notificationEnabled = true
    private var isStale = false
    private var isVisible = false

    private static let checkInterval: TimeInterval = 5 * 60
    private static let visibleDuration: TimeInterval = 5
    private static let warningEmoji = "😶"

    init(panelsProvider: @escaping () -> [OverlayPanel]) {
        self.panelsProvider = panelsProvider
    }

    /// Reset snooze and (re)arm the 5-minute check timer. Call on every
    /// transcription start path: user click, 09:00 workday entry, AC
    /// resume, heartbeat-detected auto-restart.
    func transcriptionStarted() {
        notificationEnabled = true
        isStale = false
        startCheckTimer()
    }

    /// Cancel timer and any visible overlay. Call when transcription stops.
    func transcriptionStopped() {
        checkTimer?.invalidate(); checkTimer = nil
        dismissOverlay(animated: false)
    }

    /// Forwarded from `TranscriptionWatcher.onStaleChanged`.
    func setStale(_ stale: Bool) {
        isStale = stale
    }

    // MARK: - Timer

    private func startCheckTimer() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard notificationEnabled, isStale, !isVisible else { return }
        showOverlay()
    }

    // MARK: - Overlay

    private func showOverlay() {
        let panels = panelsProvider()
        guard !panels.isEmpty else { return }
        createLayers(panels: panels)
        guard !perScreen.isEmpty else { return }
        isVisible = true
        overlayInfo("Silent transcription warning shown")
        fadeIn()
        startHoverPolling()
        scheduleAutoHide()
    }

    private func createLayers(panels: [OverlayPanel]) {
        for panel in panels {
            guard let overlayView = panel.contentView else { continue }
            overlayView.wantsLayer = true
            guard let hostLayer = overlayView.layer else { continue }
            let scale = panel.screen?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            let (bg, txt) = StatusBannerStyle.makeLayers(scale: scale)
            txt.string = Self.warningEmoji
            hostLayer.addSublayer(bg)
            hostLayer.addSublayer(txt)
            perScreen.append(PanelLayers(panel: panel, bg: bg, text: txt))
        }
    }

    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            for layers in perScreen {
                layers.bg.opacity = 1
                layers.text.opacity = 1
            }
        }
    }

    private func scheduleAutoHide() {
        visibleTimer?.invalidate()
        visibleTimer = Timer.scheduledTimer(withTimeInterval: Self.visibleDuration, repeats: false) { [weak self] _ in
            self?.dismissOverlay(animated: true)
        }
    }

    // MARK: - Hover

    private func startHoverPolling() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkHover()
        }
    }

    private func checkHover() {
        let mousePos = NSEvent.mouseLocation
        for layers in perScreen {
            guard let window = layers.panel.contentView?.window else { continue }
            let localPos = window.convertPoint(fromScreen: mousePos)
            if layers.bg.frame.contains(localPos) {
                notificationEnabled = false
                overlayInfo("Silent warning snoozed until next transcription start")
                dismissOverlay(animated: true)
                return
            }
        }
    }

    // MARK: - Teardown

    private func dismissOverlay(animated: Bool) {
        visibleTimer?.invalidate(); visibleTimer = nil
        hoverPollTimer?.invalidate(); hoverPollTimer = nil
        guard isVisible else { return }
        isVisible = false
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                for layers in self.perScreen {
                    layers.bg.opacity = 0
                    layers.text.opacity = 0
                }
            }, completionHandler: { [weak self] in
                self?.removeLayers()
            })
        } else {
            removeLayers()
        }
    }

    private func removeLayers() {
        for layers in perScreen {
            layers.bg.removeFromSuperlayer()
            layers.text.removeFromSuperlayer()
        }
        perScreen.removeAll()
    }
}
