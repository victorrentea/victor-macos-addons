import AppKit
import Foundation

/// ⌘⌃P — "remind me of this": whatever is on the clipboard right now (a
/// picture, some text, or both) is **sent** to Victor's own Gmail through
/// AgentMail's REST API, subject `Reminder`.
///
/// **Sent, not drafted** — that is the whole difference from ⌘⌃M
/// (`GmailCompose`), which fills a Gmail compose window and then waits for a
/// human to press Send. A draft is a second thing to finish; this key is done
/// the moment it is released, which is what makes it usable mid-sentence in
/// front of a room. The cost of that is symmetric: there is no confirmation
/// step, so the banner afterwards is the only proof, and it reports the real
/// HTTP outcome rather than "probably sent".
///
/// **No model, no agent, no tokens.** This is `JSONSerialization` plus one
/// `POST` to the same inbox and the same `AGENTMAIL_API_KEY` the 📬
/// `FluxInboxPoller` already uses — the same pipe, driven in the other
/// direction. Nothing here reads the clipboard *for meaning*: the bytes go out
/// exactly as they were copied. The AgentMail inbox is the **sender**; Gmail is
/// only ever the destination.
///
/// The clipboard is read, never written, so ⌘V still produces the same thing
/// afterwards.
enum ReminderMail {
    /// Hardcoded, like `FluxAgentLauncher`'s `TRUSTED_SENDER`: this shortcut
    /// mails Victor and nobody else, so no clipboard content can ever choose a
    /// recipient. A picture copied off a web page cannot become an outbound
    /// mail to an address the page put on the pasteboard.
    static let recipient = "victorrentea@gmail.com"

    /// The subject always *starts* with this word, so the whole set filters in
    /// Gmail with `subject:Reminder` no matter what was on the clipboard.
    static let subjectPrefix = "Reminder"

    /// How much of the clipboard's first line is allowed to follow the prefix.
    /// The subject line is the only part visible in a notification, so a bare
    /// `Reminder` on every mail would make an inbox of them unreadable — but a
    /// subject long enough to be truncated by the mail client answers nothing
    /// either.
    static let subjectSnippetLimit = 60

    /// The body is a note to self, not a document. Well past anything a
    /// clipboard reminder carries, and far under AgentMail's 6 MB request cap
    /// so the text can never be what makes a send fail.
    static let textLimit = 100_000

    /// Base64 inflates by 4/3, so this leaves ~5.3 MB of encoded attachment
    /// inside AgentMail's 6 MB total request limit, with room for the rest of
    /// the JSON. A full-screen retina PNG lands well over it, which is why
    /// `fit(_:)` exists.
    static let maxAttachmentBytes = 4_000_000

    /// Referenced from the HTML as `cid:clipboard`, which is what makes the
    /// picture appear *in* the mail rather than as something to click.
    static let contentId = "clipboard"

    /// Shown as the plain-text part when the clipboard held only a picture.
    /// An empty `text` renders as a blank mail in clients that prefer it, and a
    /// blank reminder is indistinguishable from a bug.
    static let imageOnlyBody = "(imagine din clipboard)"

    // MARK: What the clipboard turned out to hold

    /// The clipboard, resolved into the two things a mail can carry. Both may
    /// be present: copying from a rich source (a web page, a spreadsheet cell)
    /// puts a picture *and* its text on the pasteboard, and sending both is the
    /// only choice that cannot silently drop the half you meant.
    struct Clipping: Equatable {
        var text: String?
        var image: Image?

        struct Image: Equatable {
            var data: Data
            var filename: String
            var contentType: String
        }

        var isEmpty: Bool { (text?.isEmpty ?? true) && image == nil }
    }

    /// The raw pasteboard read, taken inside `PasteboardGate` and decoded
    /// outside it. Nothing here decodes an image or touches the disk — that is
    /// the gate's documented rule, and this type exists to carry the bytes back
    /// out of the critical section so it can be honoured.
    struct RawClip {
        var text: String?
        var png: Data?
        var tiff: Data?
        var fileURLs: [URL] = []
    }

    static func readPasteboard() -> RawClip {
        PasteboardGate.sync { pb in
            RawClip(
                text: pb.string(forType: .string),
                png: pb.data(forType: .png),
                tiff: pb.data(forType: .tiff),
                fileURLs: (pb.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
        }
    }

    static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "webp", "bmp"]

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic", "heif": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        default: return "image/png"
        }
    }

    /// Resolve the raw pasteboard into what will actually be mailed.
    ///
    /// The three image sources are tried in order of fidelity: a `public.png`
    /// (what ⌃P and macOS screenshots leave), then a `public.tiff` re-encoded
    /// to PNG (what most apps put there when you copy a picture), then an image
    /// *file* copied in Finder — which arrives as a URL, not as pixels, and
    /// would otherwise mail nothing at all.
    ///
    /// `readData` is injected so the tests can exercise the file-URL branch
    /// without a fixture on disk.
    static func clipping(from raw: RawClip,
                         readData: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> Clipping {
        var image: Clipping.Image?
        var usedFileURL: URL?

        if let png = raw.png, !png.isEmpty {
            image = Clipping.Image(data: png, filename: "clipboard.png", contentType: "image/png")
        } else if let tiff = raw.tiff, !tiff.isEmpty, let png = pngFromTIFF(tiff) {
            image = Clipping.Image(data: png, filename: "clipboard.png", contentType: "image/png")
        } else if let url = raw.fileURLs.first(where: {
            imageExtensions.contains($0.pathExtension.lowercased())
        }), let data = readData(url), !data.isEmpty {
            image = Clipping.Image(data: data,
                                   filename: url.lastPathComponent,
                                   contentType: contentType(forExtension: url.pathExtension))
            usedFileURL = url
        }

        var text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if text?.isEmpty ?? true { text = nil }
        // Finder coerces a copied file into `.string` as its path/URL, so the
        // body would otherwise repeat the attachment's own location as if it
        // were a note. The picture is the reminder; the path is noise.
        if let url = usedFileURL, let t = text,
           t == url.path || t == url.absoluteString || t == url.lastPathComponent {
            text = nil
        }

        return Clipping(text: text, image: image.map(fit))
    }

    static func pngFromTIFF(_ tiff: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Bring an oversized picture under `maxAttachmentBytes` by re-encoding it
    /// as JPEG, progressively harder.
    ///
    /// Quality is spent before pixels on purpose: a reminder to yourself is
    /// read once, so JPEG artefacts cost nothing, while a screenshot scaled
    /// down far enough to fit stops being legible — which is usually the entire
    /// content of the reminder. A retina full-screen PNG (~8 MB) lands around
    /// 1–2 MB at 0.7 and never reaches the lower steps.
    static func fit(_ image: Clipping.Image) -> Clipping.Image {
        guard image.data.count > maxAttachmentBytes,
              let rep = NSBitmapImageRep(data: image.data) else { return image }

        for quality in [0.7, 0.4, 0.2] {
            guard let jpeg = rep.representation(using: .jpeg,
                                                properties: [.compressionFactor: quality]),
                  jpeg.count <= maxAttachmentBytes else { continue }
            return Clipping.Image(data: jpeg, filename: "clipboard.jpg", contentType: "image/jpeg")
        }
        // Nothing fit. Send it anyway and let AgentMail be the one to refuse:
        // a real HTTP error in the banner says more than this function
        // inventing a verdict about a picture it never managed to shrink.
        return image
    }

    // MARK: The mail

    /// `Reminder`, plus the clipboard's first real line when there is one.
    static func subject(text: String?) -> String {
        guard let line = text?
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }), !line.isEmpty else { return subjectPrefix }

        let snippet = line.count > subjectSnippetLimit
            ? String(line.prefix(subjectSnippetLimit)) + "…"
            : line
        return "\(subjectPrefix): \(snippet)"
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// HTML exists only to place the picture inline. A text-only reminder is
    /// sent as plain text — an HTML part that adds nothing is one more thing
    /// that can render wrong.
    static func html(text: String?, hasImage: Bool) -> String? {
        guard hasImage else { return nil }
        var parts: [String] = []
        if let text, !text.isEmpty {
            parts.append("<pre style=\"font: 13px -apple-system, sans-serif; white-space: pre-wrap\">"
                + escapeHTML(text) + "</pre>")
        }
        parts.append("<img src=\"cid:\(contentId)\" style=\"max-width: 100%\">")
        return parts.joined(separator: "\n")
    }

    static func truncated(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit)) + "\n…" : text
    }

    /// The AgentMail send payload.
    ///
    /// Built with a dictionary handed to `JSONSerialization`, never by string
    /// interpolation: the clipboard is arbitrary bytes, and a quote or a
    /// backslash in it must not be able to reshape the request.
    static func payload(for clip: Clipping, to recipient: String = recipient) -> [String: Any] {
        let text = clip.text.map(truncated)
        var payload: [String: Any] = [
            "to": recipient,
            "subject": subject(text: text),
            "text": text ?? (clip.image != nil ? imageOnlyBody : ""),
        ]
        if let html = html(text: text, hasImage: clip.image != nil) {
            payload["html"] = html
        }
        if let image = clip.image {
            // snake_case is load-bearing: AgentMail silently ignores camelCase
            // attachment keys, and an ignored `content_id` turns the inline
            // picture into a dangling `cid:` reference.
            payload["attachments"] = [[
                "filename": image.filename,
                "content_type": image.contentType,
                "content": image.data.base64EncodedString(),
                "content_id": contentId,
                "content_disposition": "inline",
            ]]
        }
        return payload
    }

    /// One line for the banner, saying what actually left the Mac.
    static func confirmation(for clip: Clipping) -> String {
        switch (clip.image != nil, clip.text != nil) {
        case (true, true):  return "📤 Reminder trimis (imagine + text)"
        case (true, false): return "📤 Reminder trimis (imagine)"
        default:            return "📤 Reminder trimis"
        }
    }
}

/// Sends the clipboard as a `Reminder` mail. One `POST`, no retry: the banner
/// reports the outcome and the clipboard is untouched, so ⌘⌃P again is the
/// retry.
final class ReminderMailer {
    enum SendError: LocalizedError, Equatable {
        case emptyClipboard
        case badStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case .emptyClipboard: return "clipboard gol"
            case .badStatus(let code, let detail):
                return detail.isEmpty ? "AgentMail HTTP \(code)" : "AgentMail HTTP \(code) — \(detail)"
            }
        }
    }

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Read the clipboard and mail it. Call off the main thread: the pasteboard
    /// read and the image re-encode both happen inline.
    func sendClipboard(completion: @escaping (Result<ReminderMail.Clipping, Error>) -> Void) {
        let clip = ReminderMail.clipping(from: ReminderMail.readPasteboard())
        send(clip) { result in completion(result.map { clip }) }
    }

    func send(_ clip: ReminderMail.Clipping, completion: @escaping (Result<Void, Error>) -> Void) {
        // An empty clipboard is refused here rather than at the call site, so
        // no path — key, HTTP hook, or a future one — can mail a blank Reminder.
        guard !clip.isEmpty else { completion(.failure(SendError.emptyClipboard)); return }

        guard let url = URL(string:
            "https://api.agentmail.to/v0/inboxes/\(FluxInboxPoller.inboxId)/messages/send"),
            let body = try? JSONSerialization.data(withJSONObject: ReminderMail.payload(for: clip))
        else {
            completion(.failure(SendError.badStatus(0, "could not build the request")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Generous next to the 20 s the poller uses: this one can be carrying
        // several megabytes of screenshot up a conference Wi-Fi.
        request.timeoutInterval = 60

        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let detail = String(data: data ?? Data(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200) ?? ""
                completion(.failure(SendError.badStatus(code, String(detail))))
                return
            }
            completion(.success(()))
        }.resume()
    }
}
