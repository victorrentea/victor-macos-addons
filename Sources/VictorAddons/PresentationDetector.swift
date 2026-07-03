import Foundation

/// Am I presenting / sharing my screen right now?
///
/// Presenting is the OR of two independent signals:
///  a) **Unknown external display** — a video output connected that isn't one of
///     Victor's known displays (`KnownDisplays`): a venue projector or room TV.
///     Fed in from `DisplayArrangementManager` on every settled display change.
///  b) **Live meeting** — an app is driving the `🎙️TO Zoom` virtual device
///     (Zoom / Teams / Webex / Google Meet all route their mic through it). Fed
///     in from `MeetingDetector`.
///
/// The point of knowing this is a **presentation-only, more aggressive**
/// "transcription isn't capturing anything" warning — it must nag hard while
/// Victor is live in front of a room or a call, and stay silent otherwise.
final class PresentationDetector {
    /// Fired on the main queue whenever the combined presenting state flips.
    var onPresentingChanged: ((Bool) -> Void)?

    private(set) var isPresenting = false
    private(set) var meetingActive = false
    private(set) var unknownDisplayPresent = false

    /// From `MeetingDetector.onMeetingChanged`.
    func setMeetingActive(_ active: Bool) {
        guard active != meetingActive else { return }
        meetingActive = active
        recompute()
    }

    /// From `DisplayArrangementManager` — is any connected external display NOT
    /// in the known list?
    func setUnknownDisplayPresent(_ present: Bool) {
        guard present != unknownDisplayPresent else { return }
        unknownDisplayPresent = present
        recompute()
    }

    private func recompute() {
        let presenting = meetingActive || unknownDisplayPresent
        guard presenting != isPresenting else { return }
        isPresenting = presenting
        overlayInfo("Presentation state → \(presenting ? "PRESENTING" : "not presenting") "
            + "(meeting=\(meetingActive), unknownDisplay=\(unknownDisplayPresent))")
        DispatchQueue.main.async { [weak self] in self?.onPresentingChanged?(presenting) }
    }
}
