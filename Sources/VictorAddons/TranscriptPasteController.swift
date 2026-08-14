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
    /// - Parameter pretendItIs: rewind to a stamp earlier in today's transcript
    ///   (`GET /test/transcript-picker?at=14:30`). Testing this on the live tail
    ///   only works while somebody is talking — and on battery, or after hours,
    ///   nobody is; the rewind turns any minute of the day into a test case.
    func trigger(pretendItIs: (hour: Int, minute: Int)? = nil) {
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
                let outcome = pretendItIs == nil ? await self.waitForWhisperToCatchUp() : .ready

                var parsed = TranscriptTail.parse(TranscriptTail.readTail(of: self.todayFile()))
                if let at = pretendItIs {
                    parsed = TranscriptTail.upTo(parsed, hour: at.hour, minute: at.minute)
                }
                let lines = TranscriptTail.lastSeconds(parsed, seconds: self.windowSeconds)
                guard !lines.isEmpty else {
                    overlayInfo("⌘⌃V: nothing transcribed in the last \(Int(self.windowSeconds))s")
                    NSSound(named: "Basso")?.play()
                    return
                }
                let startedDistilling = Date()
                let segments = try await TranscriptDistiller.distill(TranscriptTail.render(lines))
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
