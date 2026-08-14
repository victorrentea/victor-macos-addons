import AppKit

/// ⌘⌃V — "put what I just said on the clipboard, cleaned up."
///
/// Five steps, each in its own file: **wait** for whisper to catch up
/// (`TranscriptSettlePolicy`, with a spinner at the cursor because the wait is
/// long enough to look like a dead key), **read** the last minute
/// (`TranscriptTail`), **clean** it with the local model (`TranscriptCleaner`),
/// cut it into growing excerpts (`TranscriptLadder`), **choose** one
/// (`TranscriptPicker`) — and the choice lands on the pasteboard.
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

    /// How far back the ladder's longest rung reaches.
    private let windowMinutes = 1

    init(transcriptionFolder: URL) {
        self.transcriptionFolder = transcriptionFolder
    }

    /// The hotkey landing point. Re-pressing while a run is in flight is a
    /// no-op rather than a second run: the first thing the shortcut does is
    /// wait ~10 s in silence, which is exactly the situation that invites an
    /// impatient second press.
    func trigger() {
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
                let outcome = await self.waitForWhisperToCatchUp()
                let lines = TranscriptTail.lastMinutes(
                    TranscriptTail.parse(TranscriptTail.readTail(of: self.todayFile())),
                    windowMinutes: self.windowMinutes)
                guard !lines.isEmpty else {
                    overlayInfo("⌘⌃V: nothing transcribed in the last \(self.windowMinutes) min")
                    NSSound(named: "Basso")?.play()
                    return
                }
                let startedCleaning = Date()
                let cleaned = try await TranscriptCleaner.clean(TranscriptTail.render(lines))
                let segments = TranscriptLadder.rungs(from: cleaned)
                guard !segments.isEmpty else {
                    overlayError("⌘⌃V: the cleaner returned nothing usable")
                    NSSound(named: "Basso")?.play()
                    return
                }
                overlayInfo(String(format: "⌘⌃V: %d rungs from %d lines (%@, %.1fs)",
                                   segments.count, lines.count, TranscriptCleaner.model,
                                   Date().timeIntervalSince(startedCleaning)))
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
