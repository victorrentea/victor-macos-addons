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
            return Line(minuteOfDay: stamp.hour * 60 + stamp.minute, text: stripSpeaker(text))
        }
    }

    /// Take `Victor 🎙️: ` / `Audience: ` off the front of a line.
    ///
    /// Whisper stopped writing those on 2026-08-14 — both channels hear the whole
    /// room, so the label was a coin flip — but every transcript written before
    /// that still carries them, and this reads the *history* as often as today.
    /// Left in, the prefix travels through the cleaner and out onto the clipboard:
    /// "Victor: Da!" is not something anybody said, it is filing metadata.
    ///
    /// Deliberately matched against the **two labels whisper could ever write**
    /// (`WHISPER_ME_SPEAKER` / `WHISPER_AUDIENCE_SPEAKER`) plus an optional
    /// source glyph, rather than a general `^word:` rule — speech genuinely
    /// contains colons ("regula e asta:") and eating a real clause to tidy a
    /// legacy prefix is the worse trade.
    static func stripSpeaker(_ text: String) -> String {
        for label in ["Victor", "Audience"] where text.hasPrefix(label) {
            let rest = text.dropFirst(label.count)
            // Anything between the name and the colon must be the mic glyph:
            // one or two non-alphanumeric characters (🎙️ is a glyph plus a
            // variation selector), never a word.
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let between = rest[rest.startIndex..<colon]
            guard between.allSatisfy({ !$0.isLetter && !$0.isNumber }) else { continue }
            return rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return text
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

    /// How much *speech* one transcript line is worth.
    ///
    /// Whisper emits one line per transcribed audio chunk: `WHISPER_CHUNK_SECONDS`
    /// (6) minus `WHISPER_OVERLAP_SECONDS` (1) of genuinely new audio each. This
    /// is the only handle there is on sub-minute duration — the file's stamps are
    /// `[HH:MM]`, so nothing finer than a minute can be read off them directly.
    static let secondsPerLine: Double = 5

    /// The last `seconds` of **speech**, counted in lines rather than off the
    /// clock.
    ///
    /// Two things make this speech-time and not wall-clock, and both are what you
    /// want here. Whisper only writes a line when a chunk was loud enough to
    /// transcribe, so silence costs nothing — "the last 40 seconds" means the
    /// last 40 seconds somebody was *talking*, not 40 seconds that might be 35 s
    /// of nobody saying anything. And the count is exact where a stamp read could
    /// never be: `[HH:MM]` cannot express 40 s at all.
    ///
    /// `maxMinutesBack` is the guard on the other side. After a long pause, eight
    /// lines of speech can reach back half an hour, and distilling "the last 40
    /// seconds" out of a conversation that ended before the break would be
    /// confidently wrong. Past that bound the window is simply shorter.
    ///
    /// Always returns at least the newest line: something said is always better
    /// than an empty panel.
    static func lastSeconds(_ lines: [Line], seconds: Double, maxMinutesBack: Int = 2) -> [Line] {
        guard let anchor = lines.last?.minuteOfDay else { return [] }
        let maxLines = max(1, Int((seconds / secondsPerLine).rounded()))

        var kept: [Line] = []
        for line in lines.reversed() {
            let age = anchor - line.minuteOfDay
            guard age >= 0, age <= maxMinutesBack else { break }
            guard kept.count < maxLines else { break }
            kept.append(line)
        }
        if kept.isEmpty, let newest = lines.last { kept = [newest] }
        return kept.reversed()
    }

    /// Everything up to and including a given stamp — the "pretend it is
    /// `HH:MM`" knob behind `GET /test/transcript-picker?at=14:30`. Without it
    /// the feature can only ever be exercised on the tail of the file, i.e. only
    /// while somebody is actually talking; with it, any minute of any past
    /// session is a test case.
    static func upTo(_ lines: [Line], hour: Int, minute: Int) -> [Line] {
        let cutoff = hour * 60 + minute
        return lines.filter { $0.minuteOfDay <= cutoff }
    }

    /// A point in the archive to rewind to: a minute, and optionally a day other
    /// than today.
    struct Moment: Equatable {
        /// `yyyy-MM-dd`, or nil for today's file.
        let day: String?
        let hour: Int
        let minute: Int
    }

    /// Parse the `?at=` test parameter: `HH:MM` for today, or
    /// `YYYY-MM-DD HH:MM` / `YYYY-MM-DDTHH:MM` for any past session.
    ///
    /// The day half exists because the feature is most in need of testing at the
    /// times it is least testable — after hours, on battery, past midnight, when
    /// today's file is empty or does not exist yet. Every past session is a
    /// corpus of real, messy Whisper output; being unable to reach it meant
    /// waiting for a live room to try anything.
    ///
    /// Returns nil for anything malformed, so a typo in a URL falls back to
    /// "now" rather than to midnight of year zero.
    static func parseMoment(_ raw: String) -> Moment? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Split on the separator between date and time, accepting either the
        // ISO `T` or the space a human would type (which arrives as `%20`).
        let halves = trimmed.split(separator: trimmed.contains("T") ? "T" : " ", maxSplits: 1)

        let day: String?
        let clock: Substring
        switch halves.count {
        case 1:
            day = nil
            clock = halves[0]
        case 2:
            guard isDayStamp(halves[0]) else { return nil }
            day = String(halves[0])
            clock = halves[1]
        default:
            return nil
        }

        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return Moment(day: day, hour: hour, minute: minute)
    }

    /// `yyyy-MM-dd`, shape-checked only — a day that never had a session simply
    /// resolves to a file that does not exist, which the caller already handles.
    static func isDayStamp(_ candidate: Substring) -> Bool {
        let chars = Array(candidate)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return false }
        return chars.enumerated().allSatisfy { index, ch in
            index == 4 || index == 7 || ch.isNumber
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
        return file(in: folder, day: fmt.string(from: now))
    }

    static func file(in folder: URL, day: String) -> URL {
        folder.appendingPathComponent("\(day)-transcription.txt")
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
