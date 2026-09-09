import Foundation

/// The text a live subtitle band should be showing, kept up to date as whisper
/// appends chunks — and, crucially, **allowed to rewrite what it already said**.
///
/// ## Why anything has to be rewritten at all
///
/// `whisper_runner` transcribes in 12 s chunks with **2 s of overlap**, and
/// nothing merges that overlap at the text level (see `docs/transcription.md`):
/// re-transcribed audio surfaces as duplicated words at every boundary, measured
/// at **6.5 %** of the transcript. In a file nobody reads live that is noise a
/// summarizer absorbs. On a subtitle band it is the whole product:
///
///     …facem un refactoring pe clasa asta pe clasa asta ca să scoatem logica
///
/// So consecutive chunks have to be **seamed**, not concatenated.
///
/// ## Which copy of the overlap wins — the past, rewritten
///
/// The seam could be repaired from either side: drop the repeat off the front of
/// the arriving chunk, or drop it off the tail of what is already on screen. They
/// produce different text and the second one is right. Whisper decodes a word
/// with whatever follows it in the same chunk; the words inside the overlap sat
/// at the *end* of the older chunk, with nothing after them, and sit in the
/// *middle* of the newer one, with a full sentence of right-context behind them.
/// The newer reading of those same seconds of audio is the better-informed one.
///
/// So the overlap is cut off the **tail already on screen** and the incoming
/// chunk is taken whole. That is what "it rewrites its past as more voice comes
/// in" means here, and it is not a figure of speech: words the room has already
/// read can visibly change, because a later chunk heard them better. This is what
/// live captioning everywhere does, and the alternative — freezing the first
/// guess because it was shown once — is how a caption band ends up confidently
/// wrong for the rest of the sentence.
///
/// ## The seam is found on words, never on characters
///
/// Two seconds of speech is a handful of words, so the match is word-aligned:
/// the longest suffix of the standing text that equals a prefix of the arriving
/// chunk. Compared **folded** — case- and diacritic-insensitive, punctuation
/// dropped — because the two passes routinely disagree on exactly those (`asta.`
/// vs `asta`, `ș` vs `s`), and a seam that misses is the duplication this exists
/// to remove.
///
/// **At least two words** have to line up (`minOverlapWords`). The bound is not
/// timidity, it is what the overlap *is*: 2 s of audio at any speaking pace is
/// several words, never one. A one-word "overlap" is therefore almost always a
/// coincidence — `și`, `deci`, `and`, `so` end one chunk and open the next all
/// day long — and honouring it deletes a real word out of the middle of a
/// sentence. `maxOverlapWords` = 12 caps the other end: past a dozen words the
/// match is no longer explainable by a 2 s overlap and is some phrase the speaker
/// actually repeated, which belongs on screen twice because it was said twice.
enum CaptionStream {

    /// Genuine overlaps are multi-word; see the type comment.
    static let minOverlapWords = 2

    /// 2 s of audio cannot be more than about this many words.
    static let maxOverlapWords = 12

    /// A safety bound on how much text is carried, **not** the thing that decides
    /// what the room sees. The plate trims itself by *measured height* against the
    /// screen it is drawn on (`LiveCaptions.render`), which is the only way to be
    /// right about it: how many words fit is a question about font size, screen
    /// width and where the words wrap, and a character count answers a different
    /// question every time any of those changes. This just stops the string
    /// growing without limit between trims — comfortably more than the largest
    /// plate can show.
    static let maxCharacters = 900

    /// Fold a word to what two whisper passes can be expected to agree on.
    /// Returns `nil` for a token that is pure punctuation, so `—` between two
    /// clauses cannot break a seam that is otherwise word-for-word.
    static func fold(_ word: String) -> String? {
        let folded = word
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return folded.isEmpty ? nil : folded
    }

    /// Split on whitespace, keeping the words as written — the folding is only
    /// ever for *comparing*; what goes on screen is whisper's own text.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Whisper stamps a **speaker glyph** on the front of most lines —
    /// `[HH:MM] 🎙️ text` when it thinks Victor spoke, `👥` for the room, nothing
    /// when the classifier will not commit. On a subtitle band that is filing
    /// metadata, exactly like the `Victor:` prefixes `TranscriptTail.stripSpeaker`
    /// takes off older transcripts: the room is reading what was *said*, and a
    /// microphone icon in front of every twelve seconds of it is noise.
    ///
    /// It also quietly breaks the seam if left on — it is the first token of the
    /// arriving chunk, and the overlap the seam is looking for starts at the
    /// second one. Matched against the **two glyphs whisper can write**, in the
    /// same spirit as `stripSpeaker` matching only the two labels it could ever
    /// write, rather than a general "drop leading non-letters" rule that would
    /// eat an opening quotation mark or a dash somebody actually said.
    static func stripSpeakerGlyph(_ text: String) -> String {
        for glyph in ["🎙️", "🎙", "👥"] where text.hasPrefix(glyph) {
            return String(text.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// How many words to drop off the end of `standing` because the start of
    /// `incoming` is the same speech — 0 when the chunks do not overlap.
    ///
    /// Matched on the **folded** sequences, with punctuation-only tokens taken out
    /// of both sides first, and the answer converted back into raw words at the
    /// end. Doing it the other way round — folding a fixed-size raw window — makes
    /// a lone `—` sitting on the seam shorten one side and lose an overlap that is
    /// otherwise word-for-word.
    ///
    /// Searched **longest first**: the 2 s overlap is one contiguous run, and a
    /// short tail of a long genuine overlap also matches, so stopping at the
    /// first (shortest) hit would leave most of the duplication on screen.
    static func overlapWordCount(standing: [String], incoming: [String]) -> Int {
        let foldedTail = standing.compactMap(fold)
        let foldedHead = incoming.compactMap(fold)
        let limit = min(maxOverlapWords, foldedTail.count, foldedHead.count)
        guard limit >= minOverlapWords else { return 0 }

        var matched = 0
        for k in stride(from: limit, through: minOverlapWords, by: -1)
        where Array(foldedTail.suffix(k)) == Array(foldedHead.prefix(k)) {
            matched = k
            break
        }
        guard matched > 0 else { return 0 }

        // Back to raw words: walk the tail until `matched` real words have been
        // covered, so any punctuation caught between them goes too.
        var raw = 0
        var seen = 0
        for word in standing.reversed() {
            raw += 1
            if fold(word) != nil { seen += 1 }
            if seen == matched { break }
        }
        return raw
    }

    /// Fold `incoming` into `standing`, rewriting the overlap rather than
    /// repeating it. Returns the text the band should now show, trimmed from the
    /// left to `maxCharacters` **on a word boundary** — a band that starts
    /// mid-word reads as a rendering bug.
    static func merge(standing: String, incoming: String) -> String {
        let new = words(stripSpeakerGlyph(incoming))
        guard !new.isEmpty else { return standing }
        let old = words(standing)
        guard !old.isEmpty else { return trimToWindow(new) }

        let k = overlapWordCount(standing: old, incoming: new)
        return trimToWindow(old.dropLast(k) + new)
    }

    /// Keep the newest `maxCharacters`, cutting whole words off the front.
    static func trimToWindow<S: Sequence>(_ words: S) -> String where S.Element == String {
        var kept: [String] = []
        var length = 0
        for word in Array(words).reversed() {
            let cost = kept.isEmpty ? word.count : word.count + 1
            if length + cost > maxCharacters, !kept.isEmpty { break }
            kept.append(word)
            length += cost
        }
        return kept.reversed().joined(separator: " ")
    }
}
