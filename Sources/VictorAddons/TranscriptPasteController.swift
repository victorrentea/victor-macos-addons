import AppKit

/// 🎙️ — "give me the essence of what I just said, ready to paste."
///
/// Four steps, each in its own file: **wait** for whisper to catch up
/// (`TranscriptSettlePolicy`, with a spinner at the cursor because the wait is
/// long enough to look like a dead key), **read** the last minute
/// (`TranscriptTail`), **distill** it into five things worth pasting
/// (`TranscriptDistiller`), **choose** one (`TranscriptPicker`) — and the choice
/// lands on the pasteboard.
///
/// It only ever writes the clipboard. Simulating the paste too was tempting and
/// is wrong: by the time the picker has been read and clicked, the app that had
/// focus when the key was pressed may not be the app you want the text in, and
/// a shortcut that types a paragraph into the wrong window is worse than one
/// that makes you press ⌘V yourself.
@MainActor
final class TranscriptPasteController {
    private let transcriptionFolder: URL
    private let picker = TranscriptPicker()
    private let spinner = BusyCursorSpinner()
    private var running = false

    /// How much speech goes into the distillation.
    ///
    /// **A full minute again since 2026-09-19.** It started at 60 s, was cut to
    /// 40 s on the argument that 40 s is usually *one* thought and one thought
    /// is what compresses into a line worth pasting — and that argument lost to
    /// use. In the room the thing being reached for is rarely the last sentence
    /// on its own; it is the point that took three or four to build, and a
    /// window that stops halfway through it hands back half an idea. Averaging
    /// two thoughts into a blander line is recoverable — you pick a different
    /// slot, or press again. Cutting the thought in half is not, and it is the
    /// failure that is invisible: the panel looks exactly as convincing either
    /// way.
    private let windowSeconds: Double = 60

    /// Fired after the pick has been written to the pasteboard **and read back**
    /// — see `copyBanner`. The controller hands over finished banner text rather
    /// than a pill: it has no business knowing which screen anything is drawn on.
    var onCopied: ((String, Bool) -> Void)?

    init(transcriptionFolder: URL) {
        self.transcriptionFolder = transcriptionFolder
    }

    /// The menu row's landing point. Re-pressing while a run is in flight is a
    /// no-op rather than a second run: the first thing the shortcut does is
    /// wait ~10 s in silence, which is exactly the situation that invites an
    /// impatient second click.
    ///
    /// - Parameter pretendItIs: rewind to a moment in the archive
    ///   (`GET /test/transcript-picker?at=14:30`, or
    ///   `?at=2026-08-14%2019:18` for a past session). Testing this on the live
    ///   tail only works while somebody is talking — and on battery, after
    ///   hours, or past midnight nobody is and today's file may not even exist;
    ///   the rewind turns any minute of any recorded day into a test case.
    /// - Parameter autoPick: press row N the moment the panel is up
    ///   (`&pick=1`). Everything *after* the pick — the pasteboard write, the
    ///   read-back that verifies it, the confirmation pill — is otherwise
    ///   reachable only with a finger on a digit key, which is exactly the part
    ///   a test cannot supply.
    func trigger(pretendItIs: TranscriptTail.Moment? = nil, autoPick: Int? = nil) {
        guard !running else { return }
        if picker.isShowing { picker.close(); return }
        running = true
        spinner.show()

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.spinner.hide()
                self.running = false
            }
            do {
                // Waiting only makes sense for "now": a rewind is reading a
                // minute that was transcribed hours ago, so there is nothing
                // in flight to wait for and the 8 s floor would be pure delay.
                //
                // The wait is logged because it is the one part of this that is
                // invisible when it works and invisible when it doesn't — a run
                // that skipped it looks exactly like a run that waited, right up
                // until the newest sentence is missing from the options.
                let startedWaiting = Date()
                let outcome = pretendItIs == nil ? await self.waitForWhisperToCatchUp() : .ready
                if pretendItIs == nil {
                    overlayInfo(String(format: "🎙️: waited %.1fs for whisper (%@)",
                                       Date().timeIntervalSince(startedWaiting),
                                       outcome == .timedOut ? "gave up, still busy" : "caught up"))
                }

                let file = pretendItIs?.day.map { TranscriptTail.file(in: self.transcriptionFolder, day: $0) }
                    ?? self.todayFile()
                var parsed = TranscriptTail.parse(TranscriptTail.readTail(of: file))
                if let at = pretendItIs {
                    parsed = TranscriptTail.upTo(parsed, hour: at.hour, minute: at.minute)
                }
                let lines = TranscriptTail.lastSeconds(parsed, seconds: self.windowSeconds)
                guard !lines.isEmpty else {
                    overlayInfo("🎙️: nothing transcribed in the last \(Int(self.windowSeconds))s")
                    NSSound(named: "Basso")?.play()
                    return
                }
                let transcript = TranscriptTail.render(lines)
                let words = TranscriptDistiller.speechWordCount(in: transcript)
                guard words >= TranscriptDistiller.minWordsWorthDistilling else {
                    // Press after a lull and the window can come down to a single
                    // "Da!". There is nothing to distill, and finding that out
                    // costs twelve seconds and an error if the model is asked.
                    overlayInfo("🎙️: only \(words) words in the last \(Int(self.windowSeconds))s — nothing to distill")
                    NSSound(named: "Basso")?.play()
                    return
                }

                let startedDistilling = Date()
                let segments = try await TranscriptDistiller.distill(transcript)
                overlayInfo(String(format: "🎙️: %d options from %d lines (%@, %.1fs)",
                                   segments.count, lines.count, TranscriptDistiller.model,
                                   Date().timeIntervalSince(startedDistilling)))
                self.spinner.hide()
                self.picker.present(segments: segments,
                                    note: outcome == .timedOut ? "⚠️ whisper still busy" : nil) { [weak self] text in
                    ClipboardManager.write(text)
                    // Read it back. "It is on your clipboard" is the entire
                    // promise of this feature, and a write that did not stick —
                    // another app holding the pasteboard, a clipboard manager
                    // clearing it a beat later — is indistinguishable from one
                    // that worked until ⌘V pastes the *previous* thing into a
                    // live session. One string compare buys the difference
                    // between a confirmation and a guess.
                    let landed = ClipboardManager.read() == text
                    NSSound(named: landed ? "Tink" : "Basso")?.play()
                    if landed {
                        overlayInfo("🎙️: \(text.count) chars → clipboard")
                    } else {
                        overlayError("🎙️: clipboard write did not stick (\(text.count) chars)")
                    }
                    // The panel is centred under the cursor and gone a second
                    // later, taking the only evidence with it — the banner is
                    // what is still on screen when you go looking for ⌘V.
                    self?.onCopied?(TranscriptPasteController.copyBanner(for: text, landed: landed),
                                    landed)
                }
                if let n = autoPick {
                    // One runloop turn later: `present` has to finish putting
                    // the panel on screen before a pick can dismiss it.
                    DispatchQueue.main.async { [weak self] in self?.picker.choose(n) }
                }
            } catch {
                overlayError("🎙️ failed: \(error.localizedDescription)")
                NSSound(named: "Basso")?.play()
            }
        }
    }

    // MARK: - The copy confirmation

    /// How much of the pick the banner quotes back.
    ///
    /// The pill draws at **54 pt bold** and caps at half the screen
    /// (`BottomLeftBanner.Style`), which on this Mac's retina is ~800 pt of
    /// label — somewhere between 28 and 60 characters depending entirely on
    /// which ones: measured at that size, 30 `m`s are 1388 pt and 30 `i`s are
    /// 446 pt. **No character count can guarantee a fit**, so this is not
    /// trying to be one. It is a budget that keeps the *log* line readable and
    /// the common case whole, and the pill truncates the rest — which is why
    /// the banner carries no closing quote mark (see `copyBanner`).
    static let bannerPreviewChars = 40

    /// The pill's text: **echo the pick back**, don't count it.
    ///
    /// "📋 142 chars copied" confirms that *something* happened, which is the
    /// one thing never in doubt — a row was visibly clicked. What is in doubt
    /// is whether the row you *meant* is the text now sitting on the
    /// pasteboard, because the digit is pressed blind and the panel is gone a
    /// second later. Echoing the opening clause answers exactly that, and costs
    /// nothing: it is a sentence said out loud half a minute ago.
    ///
    /// **No quotation marks**, and that is the one non-obvious decision here.
    /// They were there first and looked wrong the moment it ran: the pill caps
    /// at half the screen and truncates past it, so the closing `”` is the
    /// first thing to go and what is left reads as a bug — an opened quote that
    /// never closes. Unquoted, a truncated echo is just a truncated echo, and
    /// the 📋 already says what the line is.
    ///
    /// Newlines are collapsed because the pill is one line and a raw `\n`
    /// would cut the echo at the break instead.
    static func copyBanner(for text: String, landed: Bool) -> String {
        guard landed else { return "📋❌ clipboard write failed" }
        let flat = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > bannerPreviewChars else { return "📋 \(flat)" }
        return "📋 " + String(flat.prefix(bannerPreviewChars)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Waiting

    /// Poll the transcript's size until `TranscriptSettlePolicy` says whisper
    /// has drained its backlog. Runs off the main actor's critical path via
    /// `Task.sleep`, so the spinner keeps spinning throughout.
    private func waitForWhisperToCatchUp() async -> TranscriptSettlePolicy.Decision {
        let file = todayFile()
        let start = Date()
        var lastSize = TranscriptTail.size(of: file)
        var lastGrowth = start

        while true {
            let now = Date()
            let elapsed = now.timeIntervalSince(start)
            let decision = TranscriptSettlePolicy.decide(elapsed: elapsed,
                                                         sinceLastGrowth: now.timeIntervalSince(lastGrowth))
            if decision != .wait { return decision }

            try? await Task.sleep(nanoseconds: UInt64(TranscriptSettlePolicy.pollInterval * 1_000_000_000))

            let size = TranscriptTail.size(of: file)
            if size != lastSize {
                lastSize = size
                lastGrowth = Date()
            }
        }
    }

    private func todayFile() -> URL {
        TranscriptTail.todayFile(in: transcriptionFolder)
    }
}
