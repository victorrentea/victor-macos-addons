import AppKit

/// ⌘⌃V — "give me the essence of what I just said, ready to paste."
///
/// Four steps, each in its own file: **wait** for whisper to catch up
/// (`TranscriptSettlePolicy`, with a spinner at the cursor because the wait is
/// long enough to look like a dead key), **read** the last 40 seconds
/// (`TranscriptTail`), **distill** them into seven things worth pasting
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
    /// Was a full minute; 40 s is the better window because the options are
    /// *distillations*, not excerpts — over a whole minute the model has to
    /// average two or three separate thoughts into one "point of view", and the
    /// answer comes out true but bland. 40 s is usually one thought, and one
    /// thought is what compresses into a line worth pasting.
    private let windowSeconds: Double = 40

    init(transcriptionFolder: URL) {
        self.transcriptionFolder = transcriptionFolder
    }

    /// The hotkey landing point. Re-pressing while a run is in flight is a
    /// no-op rather than a second run: the first thing the shortcut does is
    /// wait ~10 s in silence, which is exactly the situation that invites an
    /// impatient second press.
    ///
    /// - Parameter pretendItIs: rewind to a moment in the archive
    ///   (`GET /test/transcript-picker?at=14:30`, or
    ///   `?at=2026-08-14%2019:18` for a past session). Testing this on the live
    ///   tail only works while somebody is talking — and on battery, after
    ///   hours, or past midnight nobody is and today's file may not even exist;
    ///   the rewind turns any minute of any recorded day into a test case.
    func trigger(pretendItIs: TranscriptTail.Moment? = nil) {
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
                    overlayInfo(String(format: "⌘⌃V: waited %.1fs for whisper (%@)",
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
                    overlayInfo("⌘⌃V: nothing transcribed in the last \(Int(self.windowSeconds))s")
                    NSSound(named: "Basso")?.play()
                    return
                }
                let transcript = TranscriptTail.render(lines)
                let words = TranscriptDistiller.speechWordCount(in: transcript)
                guard words >= TranscriptDistiller.minWordsWorthDistilling else {
                    // Press after a lull and the window can come down to a single
                    // "Da!". There is nothing to distill, and finding that out
                    // costs twelve seconds and an error if the model is asked.
                    overlayInfo("⌘⌃V: only \(words) words in the last \(Int(self.windowSeconds))s — nothing to distill")
                    NSSound(named: "Basso")?.play()
                    return
                }

                let startedDistilling = Date()
                let segments = try await TranscriptDistiller.distill(transcript)
                overlayInfo(String(format: "⌘⌃V: %d options from %d lines (%@, %.1fs)",
                                   segments.count, lines.count, TranscriptDistiller.model,
                                   Date().timeIntervalSince(startedDistilling)))
                self.spinner.hide()
                self.picker.present(segments: segments,
                                    note: outcome == .timedOut ? "⚠️ whisper still busy" : nil) { text in
                    ClipboardManager.write(text)
                    NSSound(named: "Tink")?.play()
                    overlayInfo("⌘⌃V: \(text.count) chars → clipboard")
                }
            } catch {
                overlayError("⌘⌃V failed: \(error.localizedDescription)")
                NSSound(named: "Basso")?.play()
            }
        }
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
