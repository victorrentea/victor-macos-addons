import Cocoa

/// Periodic "no sound captured" hint while transcription is on.
///
/// Every 5 minutes after transcription starts, if the transcription file
/// has been stale (no new lines for ~3 min as reported by
/// `TranscriptionWatcher`), briefly shows a "😶" pill in the bottom-left
/// of every screen for 5 seconds. Hovering snoozes the warning until the
/// next transcription start — the pill then slides straight DOWN off the
/// bottom of the screen ("no / stop"), distinct from the plain fade used
/// when transcription stops or the un-hovered countdown lapses.
final class SilentTranscriptionWarning {
    private let banner: BottomLeftBanner
    private var checkTimer: Timer?

    private var notificationEnabled = true
    private var isStale = false

    private static let checkInterval: TimeInterval = 5 * 60
    private static let visibleDuration: TimeInterval = 5
    private static let warningEmoji = "😶"

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        banner.onHover = { [weak self] in self?.snooze() }
    }

    /// Reset snooze and (re)arm the 5-minute check timer. Call on every
    /// transcription start path: launch on AC, AC resume, or a
    /// heartbeat-detected auto-restart.
    func transcriptionStarted() {
        notificationEnabled = true
        isStale = false
        startCheckTimer()
    }

    /// Cancel timer and any visible overlay. Call when transcription stops.
    func transcriptionStopped() {
        checkTimer?.invalidate(); checkTimer = nil
        dismiss()
    }

    /// Forwarded from `TranscriptionWatcher.onStaleChanged`.
    func setStale(_ stale: Bool) {
        isStale = stale
    }

    private func startCheckTimer() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard notificationEnabled, isStale, !banner.isVisible else { return }
        overlayInfo("Silent transcription warning shown")
        // Auto-dismiss when the snooze window closes. The banner's countdown
        // pauses while the cursor is on the pill, so hovering freezes the bar
        // and keeps the warning up until the user moves away (or snoozes).
        banner.onHoverCountdownExpired = { [weak self] in self?.dismiss() }
        banner.show(text: Self.warningEmoji, hoverHint: "Hover to snooze",
                    hoverCountdown: Self.visibleDuration)
    }

    private func snooze() {
        notificationEnabled = false
        overlayInfo("Silent warning snoozed until next transcription start")
        // Snooze is a "no / stop bugging me" gesture, so the pill slides straight
        // DOWN off the bottom of the screen (dismissSinking) rather than just
        // fading — the downward motion alone reads as "dismissed / put away".
        // The plain dismiss() stays for the non-gesture exits (transcription
        // stopped, or the un-hovered countdown lapsing).
        banner.dismissSinking()
    }

    private func dismiss() {
        banner.dismiss()
    }
}
