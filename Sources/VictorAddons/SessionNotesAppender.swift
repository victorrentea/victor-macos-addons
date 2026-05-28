import AppKit
import Foundation

enum SessionNotesAppender {
    /// Set by AppDelegate at startup. The unified bottom-left banner used to
    /// surface a prompt-capture offer (hover to commit) and the short
    /// confirmation flash after a clipboard append. If unset, those requests
    /// are silently dropped.
    static weak var promptBanner: BottomLeftBanner?

    private static let promptFont = NSFont.monospacedSystemFont(ofSize: 36, weight: .bold)
    private static let promptBoxWidth: CGFloat = 640
    private static let promptVisibleDuration: TimeInterval = 20
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
        appendAndReport(text: text)
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
            banner?.dismiss()
            appendAndReport(text: captured)
        }
        banner.show(text: display, font: promptFont, boxWidth: promptBoxWidth)

        DispatchQueue.main.asyncAfter(deadline: .now() + promptVisibleDuration) { [weak banner] in
            guard pendingPrompt == trimmed else { return }
            pendingPrompt = nil
            banner?.dismiss()
        }
    }

    private static func formatPromptLabel(from text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let head = collapsed.count > 23 ? String(collapsed.prefix(23)) + "⋯" : collapsed
        return "⬆️ \(head)"
    }

    private static func appendAndReport(text: String) {
        guard let folder = ScreenshotManager.sessionFolder else {
            showResult("(no active session)")
            return
        }
        guard let notes = findNotesFile(in: folder) else {
            showResult("(no notes file)")
            return
        }
        do {
            try appendLine(text, to: notes)
            showResult("⬆️ Pasted")
            overlayInfo("Appended \(text.count) chars to \(notes.path)")
        } catch {
            showResult("⚠️ Append failed")
            overlayError("Append to notes failed: \(error)")
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
            banner.show(text: text, font: promptFont, boxWidth: promptBoxWidth)
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

    private static func appendLine(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let existing = (try? Data(contentsOf: file)) ?? Data()
        var payload = ""
        if !existing.isEmpty, existing.last != 0x0A {
            payload += "\n"
        }
        payload += "- " + text + "\n"
        if let data = payload.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

}
