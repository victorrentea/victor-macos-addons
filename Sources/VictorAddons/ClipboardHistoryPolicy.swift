import Foundation

/// One thing that passed through the clipboard, as the history remembers it.
///
/// **An image entry carries no pixels.** It is a row of metadata pointing at two
/// files on disk — the full PNG that gets pasted and a downscaled thumbnail that
/// gets *shown* — because the history is a list that lives for the whole run of
/// the app and a run of ⌃P screenshots is tens of megabytes. Victor's
/// constraint, and the reason this app can remember images where Flycut cannot:
/// what stays in memory is a filename, a size and a date.
struct ClipboardEntry: Equatable, Codable {
    enum Kind: Equatable, Codable {
        case text(String)
        /// `bytes` is the PNG on disk; the pixel size is what the footer shows
        /// and what the overlay scales from.
        case image(pixelWidth: Int, pixelHeight: Int, bytes: Int)
    }

    /// Also the filename stem of an image entry's two files: `<id>.png` and
    /// `<id>-thumb.png`.
    let id: String
    let kind: Kind
    /// When it was copied — the one piece of provenance this picker shows.
    /// Victor does not want to know *which app* a clip came from (Flycut's
    /// answer, and the wrong question when you are looking for something you
    /// copied twice in the same editor); he wants to know *when*.
    var copiedAt: Date
    /// What makes two clips "the same" for the move-to-front rule: the text
    /// itself, or the SHA-256 of the image bytes. Comparing image *files* would
    /// mean reading both off disk on every copy.
    let fingerprint: String

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }

    /// What the entry costs on disk. Text rows are counted as zero: they live in
    /// the index file, and the byte ceiling exists to bound the image folder.
    var diskBytes: Int {
        if case .image(_, _, let bytes) = kind { return bytes }
        return 0
    }
}

/// The rules of the list — insertion, de-duplication, and the two ceilings that
/// keep the folder from growing forever. Pure and unit-tested, like
/// `ScreenshotRetentionPolicy`, because every one of these rules is a decision
/// that is easy to get subtly wrong and impossible to notice going wrong: a
/// history that quietly drops the clip you wanted looks exactly like a history
/// that never had it.
enum ClipboardHistoryPolicy {
    /// How many clips are remembered. Flycut's default is 40 and it is a good
    /// number for the same reason: the picker is walked with repeated presses,
    /// so the end of the list has to be reachable by hand.
    static let maxEntries = 40
    /// The image folder's ceilings. **Age first**: a clip from last week is not
    /// what ⌘⇧V is for, and the folder is in `~/Library/Caches` precisely so
    /// that nobody has to think about it.
    static let maxAge: TimeInterval = 3 * 24 * 3600
    /// ~40 retina screenshots. A backstop for a heavy day, not the usual bound.
    static let maxBytes = 400 * 1024 * 1024

    /// Put `entry` at the front, newest-first, and report what fell off.
    ///
    /// A clip that is already in the list is **moved** rather than added, and
    /// its date is refreshed to this copy — you just copied it again, so "2
    /// minutes ago" is now the truth and the older stamp is not. This is also
    /// what keeps a burst of ⌘C on the same word from filling the whole picker
    /// with one string, which is the single most annoying thing a clipboard
    /// history can do.
    ///
    /// - Returns: the new list (newest first) and the entries that must have
    ///   their files deleted — the ones pushed past `limit`, plus the duplicate
    ///   that was replaced (its PNG is a second copy of bytes we already keep).
    static func insert(_ entry: ClipboardEntry,
                       into list: [ClipboardEntry],
                       limit: Int = maxEntries) -> (list: [ClipboardEntry], evicted: [ClipboardEntry]) {
        var evicted = list.filter { $0.fingerprint == entry.fingerprint && $0.id != entry.id }
        var kept = list.filter { $0.fingerprint != entry.fingerprint }
        kept.insert(entry, at: 0)
        if kept.count > limit {
            evicted.append(contentsOf: kept[limit...])
            kept = Array(kept[..<limit])
        }
        return (kept, evicted)
    }

    /// Which entries the age and size ceilings say to drop, given a newest-first
    /// list.
    ///
    /// **The newest entry always survives**, for the same reason the screenshot
    /// folder's does: a machine that comes back from sleep with a wrong clock
    /// must not be able to throw away the thing that was copied one second ago.
    static func expired(_ list: [ClipboardEntry],
                        now: Date,
                        maxAge: TimeInterval = maxAge,
                        maxBytes: Int = maxBytes) -> [ClipboardEntry] {
        guard !list.isEmpty else { return [] }
        var doomed: [ClipboardEntry] = []
        var total = 0
        for (index, entry) in list.enumerated() {
            if index == 0 {
                total += entry.diskBytes
                continue
            }
            let tooOld = now.timeIntervalSince(entry.copiedAt) > maxAge
            // A text clip costs nothing on disk, so the byte ceiling must not
            // be able to touch it: one 40 MB screenshot at the head of the list
            // would otherwise take every text clip behind it down with it, and
            // the ceiling exists to bound the *image folder*.
            let tooBig = entry.diskBytes > 0 && total + entry.diskBytes > maxBytes
            if tooOld || tooBig {
                doomed.append(entry)
            } else {
                total += entry.diskBytes
            }
        }
        return doomed
    }

    /// The caption under a clip: **when** it was copied, in the words a glance
    /// can read. This replaces the source app Flycut prints — see
    /// `ClipboardEntry.copiedAt`.
    ///
    /// Deliberately coarse. The picker is read in a second, mid-sentence, and
    /// "4 minutes ago" answers *which copy is this* where "4m 12s" makes you
    /// do arithmetic. Past a day the clock stops mattering at all, which is
    /// also roughly where `maxAge` ends the story.
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        switch s {
        case ..<10:    return "just now"
        case ..<90:    return "a minute ago"
        case ..<3600:  return "\(Int((s / 60).rounded())) minutes ago"
        case ..<5400:  return "an hour ago"
        case ..<86400: return "\(Int((s / 3600).rounded())) hours ago"
        case ..<172800: return "yesterday"
        default:       return "\(Int(s / 86400)) days ago"
        }
    }

    /// A text clip as the bezel shows it: **the way it was copied, line breaks
    /// and all**.
    ///
    /// The first version collapsed every run of whitespace into one space, on
    /// the theory that a clip has to read as one thing in a list. It does not
    /// have a list — it has a quarter of the screen for one clip, and the
    /// shape of what you copied (an indented block, a stack trace, three
    /// paragraphs) is most of how you recognise it. Flattening that threw away
    /// the one cue the box was big enough to show. Victor, 2026-09-21: *"should
    /// show the text as it was copied along with the new lines, as much as fits
    /// the area in which it is displayed"*.
    ///
    /// What is still normalised is only what would waste that area: CRLF and
    /// lone CR become `\n`, a tab becomes four spaces (a real tab jumps to the
    /// label's default tab stop and throws indentation off), trailing blanks go
    /// per line, a run of blank lines squeezes to one, and blank lines at
    /// either end are dropped so the first line starts at the top of the box.
    ///
    /// `limit` is a **safety stop, not the visible cut**: how much shows is
    /// decided by the box, in `ClipboardHistoryOverlay.textView`, which fills it
    /// to the last line that fits and truncates there. The cap only keeps a
    /// pasted 4 MB log from being laid out in full for nothing.
    static func preview(_ text: String, limit: Int = 4000) -> String {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        var lines: [String] = []
        for raw in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while line.last == " " { line.removeLast() }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let body = lines.joined(separator: "\n")
        guard body.count > limit else { return body }
        return String(body.prefix(limit)) + "…"
    }
}
