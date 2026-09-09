import Foundation

/// 🏁 The end-of-training sequence: the room goes quiet, a finish-line bar runs
/// out, and "over and out" plays itself.
///
/// ## What it is for
///
/// The last minutes of a workshop have no ending — the slides are done, but
/// somebody is still finishing a question, somebody else is packing up, and
/// Victor cannot both hold the last conversation and watch for the moment the
/// room has actually stopped. So he arms this from the tablet (🏁, left of the
/// 3s button) at whatever point he decides the training is over, and then simply
/// keeps talking. The sequence waits out the tail of the session and closes it.
///
/// ## The two clocks, and why there are two
///
/// **Silence first** (`silenceRequired`): nothing at all happens while anyone is
/// still making noise. Only after a full stretch of quiet does the countdown
/// begin — a pause for breath mid-sentence must not be mistaken for the end of
/// the session, and ten seconds is far longer than any of those.
///
/// **Then the countdown** (`countdown`), drawn as the ordinary yellow
/// `ProgressBarOverlay` with a 🏁 riding its leading edge, so the room can see
/// the session ending and has one last window to speak into. A single word in
/// that window sends it **all the way back to waiting**: the bar disappears and
/// the full silence stretch has to be earned again. That is the point of
/// splitting the wait in two — the silence phase decides *whether* we are
/// ending, the countdown phase is the announcement, and an announcement that
/// someone talks over was wrong and must be withdrawn, not paused.
///
/// ## Where "someone spoke" comes from
///
/// Not from a second microphone tap. `whisper_runner.py` is already listening on
/// **both** channels that matter — Victor's XLR/wireless mic and the room feed
/// coming back from Zoom — and already computes a per-block RMS against a
/// per-device threshold to decide what is worth transcribing. It now prints
/// `VICTOR_VOICE:<label>` (throttled to once a second) whenever a block clears
/// that bar, and `WhisperProcessManager` forwards it here. So "the room is
/// quiet" means exactly what "whisper has nothing to transcribe" means, on the
/// same devices with the same thresholds — one definition of silence for the
/// whole app, tuned by two years of use, instead of a second one that would
/// disagree with it on exactly the hard cases.
///
/// The consequence to know: with whisper stopped (it is AC-power-driven), no
/// pulses ever arrive, the room reads as silent from the moment of arming, and
/// the sequence runs its full 10 + 10 s and fires. That is why arming is a
/// toggle — press 🏁 again to call it off.
final class TrainingEndSequence {

    /// Pure decision, so the two clocks can be tested without a microphone,
    /// a timer, or a screen. See `TrainingEndPolicyTests`.
    enum Policy {
        /// A pause for breath is a second or two; a room that has finished is
        /// quiet for much longer. Ten seconds sits clear of the first and well
        /// inside the patience of the second.
        static let silenceRequired: TimeInterval = 10

        /// Long enough to be seen, read and interrupted from the back of the room.
        static let countdown: TimeInterval = 10

        enum Phase: Equatable {
            case listening              // waiting out `silenceRequired` of quiet
            case countingDown(since: Date)
        }

        enum Action: Equatable {
            case wait
            case startCountdown
            /// Someone spoke over the countdown — withdraw it and wait again.
            case abortCountdown
            case finish
        }

        static func decide(phase: Phase, now: Date, lastVoiceAt: Date) -> Action {
            switch phase {
            case .listening:
                return now.timeIntervalSince(lastVoiceAt) >= silenceRequired
                    ? .startCountdown : .wait
            case .countingDown(let since):
                // Strictly after the countdown began: a pulse from the same instant
                // is the voice that fell silent, not a new interruption.
                if lastVoiceAt > since { return .abortCountdown }
                return now.timeIntervalSince(since) >= countdown ? .finish : .wait
            }
        }
    }

    /// Show the finish-line bar for this many seconds.
    var onStartCountdown: ((TimeInterval) -> Void)?
    /// Take the bar down — someone spoke over it.
    var onAbortCountdown: (() -> Void)?
    /// The session is over.
    var onFinish: (() -> Void)?
    /// Armed / disarmed, for logging and the menu bar.
    var onArmedChanged: ((Bool) -> Void)?

    private(set) var isArmed = false
    private var phase: Policy.Phase = .listening
    private var lastVoiceAt = Date.distantPast
    private var ticker: Timer?

    /// The tick is the ONLY authority on when the countdown is over — the bar is
    /// told how long to run and is never asked when it finished, so there is no
    /// second clock to race. A tenth of a second is therefore the worst the payoff
    /// can lag the fill reaching the right edge, which is under the bar's own fade.
    private static let tickInterval: TimeInterval = 0.1

    func toggle() { isArmed ? disarm() : arm() }

    func arm() {
        guard !isArmed else { return }
        isArmed = true
        phase = .listening
        // Victor is holding the tablet and almost certainly mid-sentence, so the
        // press itself counts as voice: the silence stretch is measured from now,
        // never from a stale pulse that would let the countdown open immediately.
        lastVoiceAt = Date()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        onArmedChanged?(true)
        overlayInfo("🏁 Training end armed — waiting for \(Int(Policy.silenceRequired))s of silence")
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        ticker?.invalidate()
        ticker = nil
        if case .countingDown = phase { onAbortCountdown?() }
        phase = .listening
        onArmedChanged?(false)
        overlayInfo("🏁 Training end cancelled")
    }

    /// One pulse of "somebody is making noise", from whisper's per-block RMS gate.
    func noteVoice() {
        lastVoiceAt = Date()
        guard isArmed else { return }
        // Don't wait up to a tick to pull the bar: the room has to see that its
        // interruption landed while the person is still speaking, not a moment later.
        if case .countingDown = phase { tick() }
    }

    private func tick() {
        guard isArmed else { return }
        switch Policy.decide(phase: phase, now: Date(), lastVoiceAt: lastVoiceAt) {
        case .wait:
            break
        case .startCountdown:
            phase = .countingDown(since: Date())
            overlayInfo("🏁 Room quiet — \(Int(Policy.countdown))s countdown")
            onStartCountdown?(Policy.countdown)
        case .abortCountdown:
            phase = .listening
            overlayInfo("🏁 Someone spoke — countdown reset")
            onAbortCountdown?()
        case .finish:
            // Retire the sequence BEFORE the payoff: "over and out" comes out of the
            // speakers loudly enough for the mic to hear it, and a still-armed
            // sequence would take its own sound for the room talking.
            isArmed = false
            ticker?.invalidate()
            ticker = nil
            phase = .listening
            onArmedChanged?(false)
            overlayInfo("🏁 Training over — over and out")
            onFinish?()
        }
    }
}
