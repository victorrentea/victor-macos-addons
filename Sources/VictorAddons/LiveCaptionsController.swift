import AppKit
import Foundation

/// **Live subtitles: the switch, and everything that has to be true while it is
/// on** (2026-09-19).
///
/// One feature, one switch, and no schedule — Victor's own framing when the
/// engine question came up: *"Doar cand activez subtitrarile din meniul macos
/// addons, doar atunci pleaca vocile streaming la eleven labs, aparand pe ecran
/// live. Doar cat sunt subtitles pornite."*
///
/// It is **not** part of 💬 Transcribing and deliberately does not live in its
/// submenu. That one is the continuous, local, free one: `mlx-whisper`, two
/// channels, on AC, writing the day's transcript that the 🎙️ picker and the
/// summarizer read. This one is a projector feature that costs $0.39 an hour and
/// sends the room's voices off this Mac. Nesting it under the other would say
/// they are the same thing turned up, and they are opposites.
///
/// ## The three things a switch like this must do
///
/// - **Say it is on where he can see it.** The row carries the minutes and the
///   dollars, the same rule the 🔴 raw capture keeps its hours under: a state
///   you cannot see is a state you forget to turn off, and this one bills.
/// - **Never fail quietly.** A subtitle band that stops updating looks exactly
///   like a room that has gone quiet. Every way this can end — the socket drops,
///   the key is wrong, the microphone goes — takes the feature down, says so on
///   the band, and repaints the row.
/// - **Leave nothing running.** The microphone and the socket both close on the
///   way out, including when the app quits mid-sentence.
final class LiveCaptionsController {

    private let stream = LiveCaptionsStream()
    private let overlay = LiveCaptionsOverlay()

    /// Repaint the menu row — the title is a readout and it goes stale by the
    /// minute.
    var onStateChange: (() -> Void)?
    /// Something worth a bottom-left pill, with a Basso behind it. Only ever a
    /// failure — the switch moving on purpose is `onSwitched`.
    var onFailed: ((String) -> Void)?

    /// **The switch moved, either way**, said on the *trainer's* screen.
    ///
    /// Restored from `4dba31a`, which arrived at it by watching the removed
    /// feature fail rather than by reasoning about it: the band draws on the
    /// built-in retina **for the room**, and the person who flipped the switch
    /// is usually looking at another screen entirely — so the one thing missing
    /// was the switch saying so where *he* is. The obvious counter-argument
    /// ("he turned it on himself, he knows") is the one that was tried first and
    /// did not survive contact: what he can see from the other screen is not the
    /// band, it is a menu he has already closed.
    ///
    /// Deliberately **not** folded into `onStateChange`, which also fires once a
    /// second while the menu is open so the minutes in the row can age in place
    /// — that would raise a pill every second.
    var onSwitched: ((Bool) -> Void)?

    private var startedAt: Date?

    private(set) var isOn = false

    /// **Why it is not on**, kept after the fact. `overlayInfo` writes into an
    /// in-app log window, which a script cannot read — so without this the only
    /// witness to a failed start is a pill that has already faded. Read by
    /// `GET /test/live-captions/state`.
    private(set) var lastError: String?

    // MARK: - The switch

    func toggle() {
        isOn ? stop(why: nil) : start()
    }

    func start() {
        guard !isOn else { return }
        overlay.show()
        // Said before the first word, because there is a second or two of socket
        // and model between the click and anything appearing, and a band that
        // comes up empty reads as broken.
        overlay.say("…")

        stream.onPartial = { [weak self] text in self?.overlay.update(partial: text) }
        stream.onCommitted = { [weak self] text in self?.overlay.commit(text) }
        stream.onClosed = { [weak self] why in
            // The socket ending is the feature ending. `stop` is safe to call
            // from here — it is idempotent and this is already on main.
            self?.stop(why: why ?? "the connection closed")
        }

        // **Optimistic, and corrected a beat later.** The microphone is opened
        // off the main thread now (it can block, and this app is the menu bar),
        // so the row goes on immediately and the failure — if there is one —
        // takes it back. The alternative is a click that does nothing visible
        // for a second, which is a click people make twice.
        isOn = true
        lastError = nil
        startedAt = Date()
        onStateChange?()
        onSwitched?(true)
        stream.start { [weak self] why in
            guard let self = self, let why = why else { return }
            self.isOn = false
            self.startedAt = nil
            self.lastError = why
            self.overlay.hide()
            overlayError("LiveCaptions: \(why)")
            self.onFailed?("🎬 subtitles: \(why)")
            self.onStateChange?()
        }
    }

    /// - Parameter why: nil when Victor turned it off himself, which needs no
    ///   explanation and gets none.
    func stop(why: String?) {
        // **`overlay.isVisible` is in this guard because of `preview`.** A
        // `/test/live-captions/say` puts the band up without ever starting the
        // stream, so `isOn` is false — and the first version of this guard
        // therefore returned early and left a black band across the bottom of
        // the projected screen with nothing able to take it down but a restart
        // of the app. Caught on 2026-09-19 doing exactly that: `?on=0` answered
        // `{"ok":true,"on":false}` while the panel was still on screen. The
        // switch has to be able to undo everything that can put the band up,
        // not just the path it knows about.
        guard isOn || stream.isRunning || overlay.isVisible else { return }
        let wasOn = isOn
        stream.stop()
        let spent = minutes
        isOn = false
        startedAt = nil
        if let why = why {
            lastError = why
            // **The band stays up for a moment saying why.** It is the one place
            // he is already looking: the alternative is a room watching a
            // subtitle area that has simply stopped, with the explanation in a
            // log file.
            overlay.say("🎬 subtitles stopped — \(why)")
            overlayError("LiveCaptions stopped: \(why)")
            onFailed?("🎬 subtitles stopped — \(why)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard self?.isOn == false else { return }
                self?.overlay.hide()
            }
        } else {
            overlay.hide()
            overlayInfo(String(format: "LiveCaptions off — %.0f min, $%.2f", spent, spent / 60 * LiveCaptionsStream.dollarsPerHour))
            // Only on a deliberate stop of something that was actually running:
            // a failure already raises its own pill carrying the reason, and
            // clearing a `preview` band never turned anything on to report off.
            if wasOn { onSwitched?(false) }
        }
        onStateChange?()
    }

    /// **Words on the band with nobody talking** — the only way to check how a
    /// caption *lays out* on the projector without standing in front of it
    /// saying sentences. It draws into the same two inks the socket feeds, so
    /// what it shows is what a real one would look like.
    func preview(committed: String?, partial: String?) {
        overlay.show()
        if let committed = committed, !committed.isEmpty { overlay.commit(committed) }
        if let partial = partial { overlay.update(partial: partial) }
    }

    /// Everything `GET /test/live-captions/state` answers with, so the endpoint
    /// stays one line and this stays the only place that knows the shape.
    var diagnostics: [String: Any] {
        ["on": isOn,
         "error": lastError ?? NSNull(),
         "key": LiveCaptionsStream.apiKey() != nil,
         "device": stream.deviceName,
         "lastMessage": stream.lastMessage ?? NSNull(),
         "chunksSent": stream.chunksSent,
         "partials": stream.partials,
         "commits": stream.commits]
    }

    /// The app is going away. Nothing may outlive it holding a microphone.
    func shutdown() {
        stream.abandon()
        overlay.hide()
        isOn = false
    }

    // MARK: - What the row says

    private var minutes: Double {
        guard let startedAt = startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt) / 60
    }

    /// **`🎬 Live subtitles — 12 min · $0.08 · DJI MIC`** while it runs.
    ///
    /// Three facts and each earns its place: *how long* because the cost is a
    /// rate and a rate needs a duration to mean anything; *how much* because the
    /// whole reason this is a switch and not a power rule is that it bills; and
    /// *which microphone*, because the one failure that looks like the feature
    /// being bad at its job is the feature listening to the wrong thing.
    var menuTitle: String {
        guard isOn else { return "🎬 Live Captions" }
        let spent = minutes
        return String(format: "🎬 Live Captions — %.0f min · $%.2f · %@",
                      spent, spent / 60 * LiveCaptionsStream.dollarsPerHour,
                      stream.deviceName)
    }
}
