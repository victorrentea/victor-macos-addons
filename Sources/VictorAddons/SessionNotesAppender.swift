import AppKit
import Foundation
import UserNotifications

enum SessionNotesAppender {
    /// Set by AppDelegate after the banner is constructed. `offerPrompt`
    /// shows the bottom-left hover banner on this instance; if unset, the
    /// prompt is silently dropped (with a log line).
    static weak var promptBanner: PromptCaptureBanner?

    private static var pendingPrompts: [String: String] = [:]
    private static let pendingLimit = 20

    static func appendClipboard() {
        let text = ClipboardManager.read().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            notify(title: "Clipboard empty", body: "Nothing to append to session notes.")
            return
        }
        appendAndReport(text: text)
    }

    /// Offer to append `text` to the current session notes via the bottom-left
    /// hover banner. No-op when there is no active session folder.
    static func offerPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard ScreenshotManager.sessionFolder != nil else { return }
        guard let banner = promptBanner else {
            overlayInfo("PromptCaptureBanner not set; dropping prompt-capture request")
            return
        }

        let id = UUID().uuidString
        pendingPrompts[id] = trimmed
        if pendingPrompts.count > pendingLimit, let key = pendingPrompts.keys.first {
            pendingPrompts.removeValue(forKey: key)
        }

        banner.show(text: trimmed, id: id)
    }

    /// Called by the notification action handler when "Add to notes" is tapped.
    static func acceptPendingPrompt(id: String) {
        guard let text = pendingPrompts.removeValue(forKey: id) else { return }
        appendAndReport(text: text)
    }

    /// Called when the user skips or dismisses the prompt-capture notification.
    static func discardPendingPrompt(id: String) {
        pendingPrompts.removeValue(forKey: id)
    }

    private static func appendAndReport(text: String) {
        guard let folder = ScreenshotManager.sessionFolder else {
            notify(title: "No active session", body: "Session folder unknown — start a session first.")
            return
        }
        guard let notes = findNotesFile(in: folder) else {
            notify(title: "No notes file", body: "No .txt file found in \(folder.lastPathComponent).")
            return
        }
        do {
            try appendLine(text, to: notes)
            let topic = stripDatePrefix(folder.lastPathComponent)
            notify(title: "Pasted in notes of \(topic)", body: preview(of: text, max: 120))
            overlayInfo("Appended \(text.count) chars to \(notes.path)")
        } catch {
            notify(title: "Append failed", body: "\(error.localizedDescription)")
            overlayError("Append to notes failed: \(error)")
        }
    }

    private static func preview(of text: String, max: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > max ? String(single.prefix(max)) + "…" : single
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

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let identifier = "session-notes-append-\(UUID().uuidString)"
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { overlayInfo("Session notes notification error: \(err)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }
}
