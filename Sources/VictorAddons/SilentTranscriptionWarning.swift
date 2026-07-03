import Cocoa

/// Aggressive "transcription isn't capturing anything" warning — **only while
/// Victor is presenting** (a venue projector connected, or a live Zoom/Teams/
/// Webex/Meet call; see `PresentationDetector`).
///
/// The whole point: during a live session, silent transcription is a real
/// failure Victor must notice *now*. So instead of the old gentle 5-minute "😶"
/// pill that showed anytime, this shows a **big red banner the moment
/// transcription goes stale during a presentation and keeps it on screen until
/// transcription recovers or the presentation ends** — with a chime on
/// appearance. Hovering snoozes it for the current stale episode (the pill sinks
/// straight down, the "put away" gesture); it re-arms once transcription
/// recovers, the presentation ends, or transcription restarts.
///
/// When **not** presenting, this stays completely silent regardless of
/// staleness — outside a live session a transcription gap doesn't matter.
final class SilentTranscriptionWarning {
    private let banner: BottomLeftBanner

    private var running = false
    private var stale = false
    private var presenting = false
    private var snoozed = false

    private static let warningText = "🔴 Transcription silent!"
    private static let warningColor = NSColor.systemRed.withAlphaComponent(0.85)
    private static let chime = NSSound(named: NSSound.Name("Basso"))

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        banner.onHover = { [weak self] in self?.snooze() }
    }

    /// Transcription came up (launch on AC, AC resume, or heartbeat restart).
    /// Clears any snooze and the stale flag; the watcher re-reports staleness.
    func transcriptionStarted() {
        running = true
        snoozed = false
        stale = false
        evaluate()
    }

    /// Transcription stopped (battery). Hide and disarm.
    func transcriptionStopped() {
        running = false
        evaluate()
    }

    /// Forwarded from `TranscriptionWatcher.onStaleChanged`.
    func setStale(_ value: Bool) {
        guard value != stale else { return }
        stale = value
        if !value { snoozed = false } // recovered → re-arm for the next episode
        evaluate()
    }

    /// Forwarded from `PresentationDetector.onPresentingChanged`.
    func setPresenting(_ value: Bool) {
        guard value != presenting else { return }
        presenting = value
        if !value { snoozed = false } // presentation ended → re-arm
        evaluate()
    }

    /// Show the warning right now regardless of gates (test hook), then
    /// auto-dismiss after a few seconds — a preview. The real, gated path stays
    /// persistent until transcription recovers / the presentation ends.
    func forceShow() {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, !self.shouldShow else { return } // don't nuke a real one
            self.banner.dismiss()
        }
    }

    private var shouldShow: Bool { running && presenting && stale && !snoozed }

    private func evaluate() {
        if shouldShow {
            if !banner.isVisible { show() }
        } else if banner.isVisible {
            banner.dismiss()
        }
    }

    private func show() {
        overlayInfo("🔴 Aggressive silent-transcription warning shown (presenting)")
        Self.chime?.play()
        // No hover-countdown → the pill is persistent: it stays until transcription
        // recovers, the presentation ends, or Victor hovers to snooze. The `.down`
        // nudge previews the sinking "put away" exit that snoozing triggers.
        banner.show(text: Self.warningText,
                    backgroundColor: Self.warningColor,
                    hoverHint: "Hover to snooze",
                    hoverNudge: .down)
    }

    private func snooze() {
        snoozed = true
        overlayInfo("🔴 Silent warning snoozed for this episode")
        banner.dismissSinking()
    }
}
