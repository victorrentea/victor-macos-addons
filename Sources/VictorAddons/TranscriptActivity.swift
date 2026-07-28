import Foundation

/// "When did somebody last actually *say* something?"
///
/// Every staleness check in the app used to answer that with the transcript
/// file's mtime, which is wrong in a way that hid a real bug for weeks: whisper
/// also writes bookkeeping lines into the same file — `--- Victor → 💻 ---`
/// device markers, one per microphone switch. Each marker bumps the mtime and so
/// silently granted another full staleness window, which is why the 😶😶😶
/// warning kept clearing itself while nothing at all was being transcribed.
///
/// Only `[HH:MM] Speaker: text` lines count as speech.
enum TranscriptActivity {
    /// Whisper writes minutes, not seconds, so the answer is coarse to ±60s.
    /// Every threshold built on it is measured in minutes, so that is fine.
    static func lastSpeechMinutes(inTail tail: String) -> (hour: Int, minute: Int)? {
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if let stamp = speechStamp(in: line) { return stamp }
        }
        return nil
    }

    /// `[14:03] Victor: hello` → `(14, 3)`. Anything else → nil.
    static func speechStamp(in line: Substring) -> (hour: Int, minute: Int)? {
        let chars = Array(line)
        guard chars.count >= 8, chars[0] == "[", chars[3] == ":", chars[6] == "]" else { return nil }
        guard let hour = Int(String(chars[1...2])), let minute = Int(String(chars[4...5])),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        // A bare `[HH:MM]` with nothing after it is not speech.
        return String(chars[7...]).trimmingCharacters(in: .whitespaces).isEmpty ? nil : (hour, minute)
    }

    /// Seconds since the last speech line in today's transcript, or `.infinity`
    /// when there has never been one today.
    ///
    /// A stamp in the *future* (the file's last line is from before midnight, or
    /// clocks moved) is treated as "just now" rather than a negative age — this
    /// probe drives restarts, and guessing "silent for -23h" would restart
    /// whisper in a loop.
    static func speechSilenceSeconds(in folder: URL, now: Date = Date(),
                                     calendar: Calendar = .current) -> TimeInterval {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let file = folder.appendingPathComponent("\(fmt.string(from: now))-transcription.txt")
        guard let tail = tail(of: file), let hm = lastSpeechMinutes(inTail: tail) else { return .infinity }
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hm.hour
        comps.minute = hm.minute
        guard let spokenAt = calendar.date(from: comps) else { return .infinity }
        return max(0, now.timeIntervalSince(spokenAt))
    }

    /// Read only the end of the file: transcripts run to megabytes over a day and
    /// this is polled every few seconds.
    private static let tailBytes = 8192

    private static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        // A tail can slice a multi-byte character in half; drop the broken
        // prefix rather than losing the whole read.
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }
}
