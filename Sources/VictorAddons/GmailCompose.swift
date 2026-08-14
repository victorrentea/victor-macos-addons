import Foundation

/// ⌘⌃M — "this belongs on my TO DO list": whatever is on the clipboard becomes
/// the body of a mail to Victor himself, subject `TO DO`, opened as a Gmail
/// draft in the browser.
///
/// **The clipboard travels in the URL, not through a simulated ⌘V.** Gmail's
/// `view=cm` compose accepts `to` / `su` / `body` as query parameters, so the
/// draft arrives already filled in — nothing has to wait for the compose window
/// to load, guess which field has focus, or post keystrokes into whatever Chrome
/// happens to show first. A paste that lands one field early writes the whole
/// note into the To: box; a URL cannot miss. The clipboard is only ever read
/// here, never written, so the text stays available for a manual ⌘V too.
///
/// No agent, no API call, no model: this is string building plus `open -a
/// "Google Chrome"`, which is what makes the shortcut instant and offline.
enum GmailCompose {
    static let subject = "TO DO"

    /// Chrome itself would swallow far more, but the URL also crosses Gmail's
    /// own servers, and a compose that answers 400 is worse than one that
    /// arrives shortened — so the whole thing is kept inside the length every
    /// link in the chain is known to accept.
    static let maxURLLength = 8000

    /// Appended to a body that had to be cut. It names where the rest is,
    /// which is the only thing the shortened draft can't show: the clipboard
    /// is untouched, so ⌘V in the body still produces the full text.
    static let truncationNotice = "\n\n[…text scurtat — originalul întreg e încă în clipboard: ⌘V]"

    struct Draft {
        let url: String
        /// True when the clipboard didn't fit and `truncationNotice` was added.
        let truncated: Bool
    }

    /// Percent-encodes for a query *value*: only the unreserved characters
    /// survive, so `&`, `=`, `#` and `+` can't end a parameter early or be
    /// read back as a space.
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The longest prefix of `text` whose encoding fits in `budget` characters.
    /// Shrinks proportionally to the overshoot (a multi-byte character costs 9
    /// encoded characters, an ASCII one 1–3, so cutting one at a time would
    /// loop thousands of times on a long clipboard) and always drops at least
    /// one character per pass, which is what guarantees it terminates.
    static func fitEncoded(_ text: String, budget: Int) -> String {
        if budget <= 0 { return "" }
        var chars = Array(text)
        while !chars.isEmpty {
            let encodedCount = encode(String(chars)).count
            if encodedCount <= budget { return String(chars) }
            let proportional = chars.count * budget / max(1, encodedCount)
            chars = Array(chars.prefix(max(0, min(chars.count - 1, proportional))))
        }
        return ""
    }

    /// Builds the Gmail compose URL for a TO DO mail to `to` carrying
    /// `clipboard` as its body.
    static func draft(clipboard: String, to: String = PasteSnippets.email) -> Draft {
        let prefix = "https://mail.google.com/mail/?view=cm&fs=1"
            + "&to=" + encode(to)
            + "&su=" + encode(subject)
            + "&body="
        let budget = max(0, maxURLLength - prefix.count)

        if encode(clipboard).count <= budget {
            return Draft(url: prefix + encode(clipboard), truncated: false)
        }
        let notice = encode(truncationNotice)
        let kept = fitEncoded(clipboard, budget: budget - notice.count)
        return Draft(url: prefix + encode(kept) + notice, truncated: true)
    }
}
