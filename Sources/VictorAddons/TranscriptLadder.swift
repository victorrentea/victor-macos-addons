import Foundation

/// The ladder the ⌘⌃V picker shows: the same cleaned minute, offered at growing
/// lengths, every rung ending on the most recent words.
///
/// This is deliberately **arithmetic, not generation**. Asking the model for the
/// five excerpts directly works, but it makes the two properties the picker
/// depends on — every rung ends at the end, and each rung strictly contains the
/// one above it — a matter of the model's good behaviour, on top of costing five
/// re-emissions of the same text. Derived from sentence boundaries here, both
/// properties hold by construction and the rungs appear instantly.
enum TranscriptLadder {

    /// Five rungs: enough of a spread to find the right length by eye, few
    /// enough that consecutive options are visibly different things.
    static let defaultRungs = 5

    /// Split cleaned prose into sentences, keeping the terminator with its
    /// sentence. Newlines end a sentence too — the model occasionally lays the
    /// minute out as paragraphs.
    ///
    /// No abbreviation handling ("e.g.", initials): a wrong split costs one rung
    /// starting a few words early, which the reader sees and skips, while the
    /// machinery to avoid it would be a permanent source of its own bugs.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""

        for ch in text {
            if ch == "\n" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
                continue
            }
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "…" {
                // Only break on the LAST character of a run of terminators, so
                // "wait…" and "really?!" stay whole.
                continue
            }
            if ch == " ", let last = current.dropLast().last,
               last == "." || last == "!" || last == "?" || last == "…" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// How many trailing sentences each rung carries: strictly increasing, first
    /// rung = 1 (the last complete thought), last rung = everything.
    ///
    /// Spaced **geometrically** rather than evenly. What the eye is choosing
    /// between is "the last sentence" / "the last thought" / "the whole thing",
    /// and those live at very different scales — evenly spaced rungs over 20
    /// sentences would offer 4, 8, 12, 16, 20, i.e. four options that are all
    /// "most of it" and none that is "just the end".
    static func counts(sentenceCount n: Int, rungs: Int = defaultRungs) -> [Int] {
        guard n > 0, rungs > 0 else { return [] }
        guard n > rungs else { return Array(1...n) }

        // `stride`, not `1..<(rungs - 1)`: at rungs == 1 that range is `1..<0`,
        // which traps rather than being empty.
        var counts = [1]
        for i in stride(from: 1, to: max(1, rungs - 1), by: 1) {
            counts.append(Int(pow(Double(n), Double(i + 1) / Double(rungs)).rounded()))
        }
        counts.append(n)
        // A one-rung ladder is just "all of it"; the seeded 1 has nothing to be
        // the short end of.
        if rungs == 1 { return [n] }

        // Rounding can flatten two rungs onto the same value (short inputs) or
        // even invert them. Push up from the left, then pull down from the
        // right: the result is strictly increasing, still starts at 1 and still
        // ends at n, because `n > rungs` leaves room for every step.
        for i in 1..<counts.count {
            counts[i] = max(counts[i], counts[i - 1] + 1)
        }
        for i in stride(from: counts.count - 2, through: 0, by: -1) {
            counts[i] = min(counts[i], counts[i + 1] - 1)
        }
        return counts
    }

    /// The finished rungs, shortest first. Empty in, empty out.
    static func rungs(from cleanedText: String, rungs count: Int = defaultRungs) -> [String] {
        let all = sentences(in: cleanedText)
        guard !all.isEmpty else { return [] }
        return counts(sentenceCount: all.count, rungs: count).map { take in
            all.suffix(take).joined(separator: " ")
        }
    }
}
