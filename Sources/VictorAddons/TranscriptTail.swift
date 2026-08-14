import Foundation

/// "What was said in the last minute?" — the read side of the ⌘⌃V picker.
///
/// Deliberately separate from `TranscriptActivity`, which answers a different
/// question ("when did somebody last say *anything*?") off a tiny 8 KB tail and
/// is polled every few seconds by the whisper watchdog. This one is asked once
/// per keypress, wants a whole minute of *content* rather than one timestamp,
/// and so reads a bigger window and keeps the text.
enum TranscriptTail {

    /// One `[HH:MM] text` line. Speaker labels no longer exist in the file —
    /// both capture channels hear the whole room, so whichever one was louder
    /// used to decide the attribution (see `whisper_runner._on_segment`).
    struct Line: Equatable {
        let minuteOfDay: Int
        let text: String
    }

    /// Parse a chunk of transcript. Anything that isn't a stamped speech line —
    /// blank lines, `--- Victor → 💻 ---` device markers, a first line the tail
    /// sliced in half — is dropped rather than guessed at.
    static func parse(_ chunk: String) -> [Line] {
        chunk.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let stamp = TranscriptActivity.speechStamp(in: line) else { return nil }
            let text = String(Array(line)[7...]).trimmingCharacters(in: .whitespaces)
            return Line(minuteOfDay: stamp.hour * 60 + stamp.minute, text: text)
        }
    }

    /// The last `windowMinutes` of speech, anchored on the **newest line in the
    /// file rather than on the wall clock**.
    ///
    /// The wall clock would be the obvious anchor and is the wrong one: whisper
    /// stamps a line when it *writes* it, several seconds after the words were
    /// spoken, and the picker is fired the instant Victor stops talking. Anchored
    /// on `now`, a minute-granularity stamp one tick behind empties the window
    /// and the feature answers "nothing was said" to somebody who has just
    /// finished a sentence.
    ///
    /// Lines stamped *later* than the anchor are yesterday's — the tail can
    /// straddle midnight only in the sense that a day file's first lines
    /// occasionally carry a pre-midnight stamp — and are dropped rather than
    /// read as ~24 h old.
    static func lastMinutes(_ lines: [Line], windowMinutes: Int) -> [Line] {
        guard let anchor = lines.last?.minuteOfDay else { return [] }
        return lines.filter { line in
            let age = anchor - line.minuteOfDay
            return age >= 0 && age <= windowMinutes
        }
    }

    /// Render for the LLM: one `[HH:MM] text` line per entry, oldest first.
    static func render(_ lines: [Line]) -> String {
        lines.map { line in
            String(format: "[%02d:%02d] %@", line.minuteOfDay / 60, line.minuteOfDay % 60, line.text)
        }.joined(separator: "\n")
    }

    // MARK: - File access

    /// A minute of speech is a couple of KB; 64 KB is a wide margin that still
    /// costs one read.
    private static let tailBytes = 65_536

    static func todayFile(in folder: URL, now: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return folder.appendingPathComponent("\(fmt.string(from: now))-transcription.txt")
    }

    /// Byte size of today's transcript, or 0 when it doesn't exist yet. This is
    /// the growth signal `TranscriptSettlePolicy` watches.
    static func size(of file: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64 ?? 0
    }

    static func readTail(of file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return "" }
        // A tail can slice a multi-byte character in half; the broken prefix
        // costs us at most the first line, which `parse` drops anyway.
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
