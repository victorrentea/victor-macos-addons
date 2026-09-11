import Foundation

/// Whether whisper should also collect utterance-sized WAVs of Victor's voice
/// for the local-model fine-tune.
///
/// **This is not `RawAudioRecording` with a different filename**, and the two
/// are deliberately separate switches. The raw capture keeps a whole day in one
/// undifferentiated PCM file so the *gate* can be studied afterwards; it is
/// armed for one workshop and it costs ~115 MB an hour whether anybody speaks or
/// not. This one keeps one WAV per sentence, only while somebody is talking,
/// only inside the work window, and it is meant to stand for months — because
/// the thing it feeds needs ten-plus hours of speech and the corpus is currently
/// gathering them a dictation at a time.
///
/// **Why it has to be collected rather than harvested.** The teacher is Wispr
/// Flow, whose database keeps every transcript forever and prunes the matching
/// *recording* after about a week — 12,186 transcripts against 185 recordings on
/// 2026-09-01. Harvesting it can therefore never reach past the last seven days.
/// Recording the microphone here inverts the dependency: the audio is ours and
/// keeps, and the label can be asked for later, including for WAVs that are
/// months old by then.
///
/// The state is a **file, not a `UserDefaults` key**, for the same three reasons
/// as the raw flag: whisper is a separate process that only learns of it through
/// its environment, a scheduled job has to be able to arm it with nobody
/// clicking anything, and `ls` has to be able to answer "was it collecting?"
/// long afterwards.
enum VoiceCorpusRecording {
    /// Beside the day's transcript, like the raw flag — the folder anyone
    /// looking for "what was this Mac recording" already opens.
    static func flagURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".collect-voice-corpus")
    }

    static func isEnabled(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: flagURL(in: folder).path)
    }

    /// - Returns: the state actually achieved. A read-only disk is a reason to
    ///   leave the menu telling the truth, not to claim a collection that will
    ///   not happen.
    @discardableResult
    static func set(_ enabled: Bool, in folder: URL) -> Bool {
        let url = flagURL(in: folder)
        if enabled {
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? stamp.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        return isEnabled(in: folder)
    }

    /// The environment whisper is launched with. Empty when off, so the runner's
    /// own `WHISPER_VOICE_CORPUS=0` default stands and exactly one place decides
    /// what "off" means.
    ///
    /// Only the switch is passed. The destination (`VOICE_CORPUS_DIR`) and the
    /// schedule (`VOICE_CORPUS_WINDOW`) are read by the Python side from the
    /// **inherited** environment, which is what lets an external disk be
    /// selected by editing the LaunchAgent rather than by shipping a new build.
    static func env(for folder: URL) -> [String: String] {
        isEnabled(in: folder) ? ["WHISPER_VOICE_CORPUS": "1"] : [:]
    }

    /// Where the samples land, mirroring `corpus_recorder.py`'s own default:
    /// inside the corpus Walkie Talkie already owns, so the harvester, the
    /// baseline and the report all see one corpus instead of two.
    ///
    /// Duplicated across the two languages on purpose — the menu has to be able
    /// to count what is on disk without asking a process that may not be
    /// running — and overridable by the same env var the Python side reads, so
    /// the duplication cannot drift into a disagreement about *which* folder.
    static func corpusFolder(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let root =
            environment["VOICE_CORPUS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".walkie-talkie/voice-corpus")
        return root.appendingPathComponent("mic")
    }

    /// How many samples were collected on `day`, and how many minutes of speech
    /// they hold.
    ///
    /// Read off the manifest rather than off the files: it is one sequential
    /// read instead of a `stat` per WAV, and — the part that matters — it knows
    /// the *speech* seconds. Counting bytes would report the disk, and the disk
    /// is not the thing that is 10 hours short.
    static func collected(day: Date = Date(), environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (samples: Int, minutes: Double)
    {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let prefix = fmt.string(from: day)
        let manifest = corpusFolder(environment: environment)
            .appendingPathComponent("mic-corpus.jsonl")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            return (0, 0)
        }
        var samples = 0
        var seconds = 0.0
        for line in text.split(separator: "\n") {
            // A cheap prefix test before paying for JSON: the day folder is in
            // every row's `wav` path, and a manifest that has been accumulating
            // for months is mostly other days.
            guard line.contains("\"\(prefix)/") else { continue }
            guard let data = line.data(using: .utf8),
                let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            samples += 1
            seconds += (row["seconds"] as? NSNumber)?.doubleValue ?? 0
        }
        return (samples, seconds / 60)
    }
}
