import AppKit
import Foundation

enum SessionNotesAppender {
    /// Set by AppDelegate at startup. The unified bottom-left banner used to
    /// surface a prompt-capture offer (hover to commit) and the short
    /// confirmation flash after a clipboard append. If unset, those requests
    /// are silently dropped.
    static weak var promptBanner: BottomLeftBanner?

    private static let promptFont = NSFont.monospacedSystemFont(ofSize: 36, weight: .bold)
    /// How long any *actionable* (hoverable) banner stays up so the user has a
    /// uniform window to react — hover-to-Send on a prompt offer, hover-to-undo
    /// after an append. Kept equal to the countdown's window for consistency.
    private static let hoverActionDuration: TimeInterval = 7.5
    /// Non-actionable flashes (errors, "Undone" confirmation) clear faster.
    private static let resultVisibleDuration: TimeInterval = 2.0
    private static var resultDismissWork: DispatchWorkItem?

    /// Prompts whose trimmed text starts with any of these prefixes are silently
    /// dropped — no banner, no notes append. Extend as new system-noise prefixes appear.
    private static let blockedPromptPrefixes: [String] = [
        "<task-notification>",
    ]

    /// Currently-pending prompt text, if any. Cleared on hover-accept or
    /// timeout. Only one prompt-capture offer is on screen at a time.
    private static var pendingPrompt: String?

    static func appendClipboard() {
        let text = ClipboardManager.read().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showResult("(empty clipboard)")
            return
        }
        pasteAndOfferUndo(text: text)
    }

    /// Copy the current selection in the frontmost app (simulated Cmd+C), then
    /// append it to the session notes — a one-key alternative to manually
    /// copying and then calling `appendClipboard`. Leaves the copied text on the
    /// clipboard, matching normal Cmd+C semantics. Run off the main thread: it
    /// blocks briefly polling the pasteboard for the copy to land.
    static func copySelectionAndAppend() {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        KeySimulator.cmdC()

        // Wait for the app to service the copy. changeCount bumps on every
        // pasteboard write (even identical content), so this reliably detects
        // whether anything was copied — apps no-op Cmd+C when nothing is selected.
        var waited: TimeInterval = 0
        let step: TimeInterval = 0.02
        while pasteboard.changeCount == before && waited < 0.5 {
            Thread.sleep(forTimeInterval: step)
            waited += step
        }
        guard pasteboard.changeCount != before else {
            showResult("(no selection)")
            return
        }

        let text = ClipboardManager.read().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showResult("(empty selection)")
            return
        }
        pasteAndOfferUndo(text: text)
    }

    /// Offer to append `text` to the current session notes via the bottom-left
    /// hover banner. No-op when there is no active session folder.
    static func offerPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if blockedPromptPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return }
        guard ScreenshotManager.sessionFolder != nil else { return }
        guard let banner = promptBanner else {
            overlayInfo("Prompt-capture banner not set; dropping request")
            return
        }

        resultDismissWork?.cancel()
        resultDismissWork = nil
        pendingPrompt = trimmed
        let display = formatPromptLabel(from: trimmed)
        banner.onHover = { [weak banner] in
            guard let captured = pendingPrompt else { return }
            pendingPrompt = nil
            // Hovering the offer is the explicit confirmation. Accepting a
            // proposed action floats the pill up into the notes — the rising
            // fade *is* the "sent" feedback, so there's no follow-up flash.
            do {
                _ = try writeNotes(captured)
                banner?.dismissRisingFade()
            } catch {
                reportWriteFailure(error)
            }
        }
        // Auto-dismiss when the hover window closes. Driven by the banner's
        // countdown (which pauses while the cursor is on the pill) rather than a
        // fixed timer, so parking the mouse on the offer keeps it up.
        banner.onHoverCountdownExpired = { [weak banner] in
            guard pendingPrompt == trimmed else { return }
            pendingPrompt = nil
            banner?.dismiss()
        }
        banner.show(text: display, font: promptFont,
                    hoverCountdown: hoverActionDuration, hoverNudge: .up)
    }

    /// Flatten newlines/tabs to single spaces so a multi-line selection shows
    /// on one banner line. Length isn't capped here — the banner box hugs the
    /// text and truncates with an ellipsis once it hits half the screen width.
    private static func singleLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Label for the prompt-capture offer: collapse to one line and prefix the
    /// up-arrow. No character cap — the banner box grows up to half the screen
    /// width and the label truncates with its own ellipsis only past that.
    private static func formatPromptLabel(from text: String) -> String {
        return "⬆️ " + singleLine(text)
    }

    enum NotesError: Error { case noSession, noNotesFile }

    /// Write a "- text" line to the active notes file, returning the file URL
    /// and the byte offset *before* the write (for undo). Throws on any failure.
    /// Banner-free: callers decide the visual feedback (rising-fade, undo offer,
    /// or an error flash) so the same write powers every entry point.
    @discardableResult
    private static func writeNotes(_ text: String) throws -> (file: URL, offset: UInt64) {
        guard let folder = ScreenshotManager.sessionFolder else { throw NotesError.noSession }
        guard let notes = findNotesFile(in: folder) else { throw NotesError.noNotesFile }
        let offset = try appendLine(text, to: notes)
        overlayInfo("Appended \(text.count) chars to \(notes.path)")
        return (notes, offset)
    }

    /// Map a `writeNotes` failure to the right bottom-left flash.
    private static func reportWriteFailure(_ error: Error) {
        switch error {
        case NotesError.noSession:   showResult("(no active session)")
        case NotesError.noNotesFile: showResult("(no notes file)")
        default:
            showResult("⚠️ Append failed")
            overlayError("Append to notes failed: \(error)")
        }
    }

    /// Direct keypress paste: write the line immediately, then show the
    /// hoverable "Hover to undo" banner. This is an *already-done* action — the
    /// user can cancel it (hover → pill sinks off-screen) or let it stand (countdown
    /// expires → rising fade).
    private static func pasteAndOfferUndo(text: String) {
        do {
            let (notes, offset) = try writeNotes(text)
            showUndoable("⬆️ Pasted: " + singleLine(text),
                         undo: { performUndo(file: notes, toOffset: offset) })
        } catch {
            reportWriteFailure(error)
        }
    }

    /// Undo the most recent append by truncating the notes file back to the
    /// byte offset captured just before the line was written — removing the
    /// "- …" line and any newline we inserted, and nothing else. If the file
    /// shrank since (shorter than the offset), there is nothing of ours left
    /// to remove, so we leave it untouched. Returns whether the undo succeeded:
    /// on success the caller sinks the banner off-screen (that *is* the "undone"
    /// feedback); on failure it has already flashed the reason.
    @discardableResult
    private static func performUndo(file: URL, toOffset offset: UInt64) -> Bool {
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let currentEnd = try handle.seekToEnd()
            guard currentEnd >= offset else {
                showResult("(nothing to undo)")
                return false
            }
            try handle.truncate(atOffset: offset)
            overlayInfo("Undid append; truncated \(file.lastPathComponent) to \(offset) bytes")
            return true
        } catch {
            showResult("⚠️ Undo failed")
            overlayError("Undo append failed: \(error)")
            return false
        }
    }

    /// Show an append confirmation that stays up for `hoverActionDuration` and
    /// can be hovered to undo the append. `undo` runs on the main thread when
    /// the hover fires and returns whether it succeeded; the captured
    /// file/offset live in the closure, so no shared undo state can race with a
    /// concurrent append.
    ///
    /// The two exits are visually distinct:
    ///   • hover-to-undo succeeds → the banner sinks down off-screen (cancelled).
    ///   • the countdown expires un-hovered → the banner floats up (committed).
    private static func showUndoable(_ text: String, undo: @escaping () -> Bool) {
        DispatchQueue.main.async {
            guard let banner = promptBanner else {
                overlayInfo("Result banner unset; would have shown: \(text)")
                return
            }
            pendingPrompt = nil
            resultDismissWork?.cancel(); resultDismissWork = nil
            banner.onHover = { [weak banner] in
                // Cancelling a done action: sink the pill off the bottom only if
                // the undo actually landed (otherwise the failure flash from
                // `undo` stays up).
                if undo() { banner?.dismissSinking() }
            }
            // Window closed un-hovered → the paste stands; float it up.
            banner.onHoverCountdownExpired = { [weak banner] in
                banner?.onHover = nil
                banner?.dismissRisingFade()
            }
            banner.show(text: text, font: promptFont,
                        hoverCountdown: hoverActionDuration, hoverNudge: .down)
        }
    }

    /// Flash a short status message in the bottom-left banner and auto-dismiss
    /// after `resultVisibleDuration`. Replaces any visible prompt-capture
    /// banner: pendingPrompt and onHover are cleared so an accidental hover
    /// on the flashing confirmation can't commit a stale prompt.
    private static func showResult(_ text: String) {
        DispatchQueue.main.async {
            guard let banner = promptBanner else {
                overlayInfo("Result banner unset; would have shown: \(text)")
                return
            }
            pendingPrompt = nil
            banner.onHover = nil
            resultDismissWork?.cancel()
            banner.show(text: text, font: promptFont)
            let work = DispatchWorkItem { [weak banner] in
                resultDismissWork = nil
                banner?.dismiss()
            }
            resultDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + resultVisibleDuration, execute: work)
        }
    }

    /// Strip the leading date prefix from a session folder name.
    /// Examples: "2026-05-15 Kafka@ITKonekt" → "Kafka@ITKonekt",
    /// "2026-05-18..22 Performance@Bloomberg" → "Performance@Bloomberg",
    /// "2026-06-05+06 AI@HEITS" → "AI@HEITS".
    private static func stripDatePrefix(_ name: String) -> String {
        if let spaceIdx = name.firstIndex(of: " ") {
            let head = name[..<spaceIdx]
            if head.first?.isNumber == true {
                let tail = name[name.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { return tail }
            }
        }
        return name
    }

    /// Most-recently modified .txt in the session folder (matches daemon `find_notes_in_folder`).
    private static func findNotesFile(in folder: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let txts = contents.filter { $0.pathExtension.lowercased() == "txt" }
        return txts.max(by: { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        })
    }

    /// Append a "- <text>" line and return the file's byte offset *before* the
    /// write, so the append can be undone by truncating back to it.
    @discardableResult
    private static func appendLine(_ text: String, to file: URL) throws -> UInt64 {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let originalEnd = try handle.seekToEnd()
        let existing = (try? Data(contentsOf: file)) ?? Data()
        var payload = ""
        if !existing.isEmpty, existing.last != 0x0A {
            payload += "\n"
        }
        payload += "- " + text + "\n"
        if let data = payload.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
        return originalEnd
    }

}
