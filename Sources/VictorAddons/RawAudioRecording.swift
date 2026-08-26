import Foundation

/// Whether whisper should also keep the raw microphone audio on disk.
///
/// This is off by default and is meant to be armed for a *specific session*: it
/// writes ~115 MB an hour and it records a room full of people who have not been
/// asked. The reason it exists at all is that the speaker-identification work has
/// no far-field corpus — every recording that survived is a Zoom mix of remote
/// participants, and the one case that matters, an audience in the room arriving
/// through Victor's own lavalier, was never captured by anything.
///
/// **The state is a file, not a `UserDefaults` key**, and that is the whole
/// design. It has to be readable and settable from outside the app: whisper is a
/// separate process that only learns about it through its environment, a
/// scheduled job needs to be able to arm it before a workshop starts without a
/// human clicking anything, and `ls` has to be able to answer "was I recording?"
/// months later. A defaults key would have been invisible to all three.
enum RawAudioRecording {
    /// Sits next to the day's transcript, so a session's recording and its text
    /// are in one place — and so the dot-file shows up right where anyone
    /// looking for the audio would already be.
    static func flagURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".record-raw-audio")
    }

    static func isEnabled(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: flagURL(in: folder).path)
    }

    /// - Returns: the state actually achieved, which is not always the state
    ///   asked for — a read-only disk is a reason to leave the menu telling the
    ///   truth rather than to claim a recording that will not happen.
    @discardableResult
    static func set(_ enabled: Bool, in folder: URL) -> Bool {
        let url = flagURL(in: folder)
        if enabled {
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            // The contents are for whoever finds this file later and wonders
            // what armed it; nothing reads them.
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? stamp.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        return isEnabled(in: folder)
    }

    /// The environment whisper is launched with. Empty when off, so the runner's
    /// own default (`WHISPER_RECORD_RAW=0`) stands and there is exactly one
    /// place that decides what "off" means.
    static func env(for folder: URL) -> [String: String] {
        isEnabled(in: folder) ? ["WHISPER_RECORD_RAW": "1"] : [:]
    }

    /// Where the audio lands — same value as the Python side's `raw-audio`
    /// subfolder. Duplicated deliberately: the menu needs to be able to reveal
    /// the folder without asking a process that may not be running.
    static func audioFolder(in folder: URL) -> URL {
        folder.appendingPathComponent("raw-audio")
    }

    /// Bytes per second of what the runner writes: 16 kHz, mono, signed 16-bit.
    /// The files are headerless PCM (a WAV only writes its frame count on close,
    /// and whisper is routinely killed outright), so duration is division.
    static let bytesPerSecond: Double = 16000 * 2

    /// How much audio is on disk for `day`, in hours — the honest measure of a
    /// recording session, and the one that tells you the disk is filling.
    static func hoursRecorded(in folder: URL, day: Date = Date()) -> Double {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dir = audioFolder(in: folder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return 0 }
        let prefix = fmt.string(from: day)
        let bytes = names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".pcm") }
            .compactMap {
                (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path))?[.size] as? NSNumber
            }
            .reduce(0.0) { $0 + $1.doubleValue }
        return bytes / bytesPerSecond / 3600
    }
}
