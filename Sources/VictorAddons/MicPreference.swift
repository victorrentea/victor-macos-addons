import Foundation

/// **The microphone Victor picked, shared with Walkie Talkie.**
///
/// Two apps on this Mac open the same six microphones — the relay for dictation,
/// this one to transcribe the room continuously — and until 2026-09-22 each kept
/// its own answer: Walkie in `UserDefaults` under `micDevice`, this app in a
/// `.preferred-me-source` file holding a CoreAudio name fragment. Same six rows
/// in two menus, and no way to tell from either what the other was listening
/// through. Victor's ask: *"când o schimb într-una, să se schimbe automat și în
/// cealaltă"*.
///
/// The contract is one file holding one id from `MicRoster.ids` (or `auto`):
///
/// ```
/// ~/.walkie-talkie/mic/choice
/// ```
///
/// **The path is Walkie Talkie's home, and that is the right way round.** This
/// repo is private and Walkie's is public; the rule is that Walkie must stay
/// usable with no knowledge of this app, so the shared state lives in *its*
/// folder and this app is the one that reaches over. There is precedent in both
/// directions already — `LiveCaptionsStream` reads
/// `~/.walkie-talkie/elevenlabs.env`, `VoiceCorpusRecording` writes into
/// `~/.walkie-talkie/voice-corpus`. Nothing here creates a dependency the other
/// way: if this app never runs, Walkie reads and writes the same file alone.
///
/// **A file rather than a route**, although both apps already run an HTTP server
/// the other one calls: a route only works while both apps are up, and the
/// microphone is picked between sessions at least as often as during one. A file
/// is the state; whoever comes up next reads it.
///
/// ## Two files, one direction
///
/// The Python transcriber has its own preference file (`.preferred-me-source`,
/// watched by `whisper_runner.py` so a change takes effect without a restart)
/// and it holds a **CoreAudio name fragment**, not an id. That file stays: it is
/// the engine's own input and translating at the boundary is cheaper than
/// teaching Python the roster's ids. `AppDelegate` writes it from whatever
/// lands in `choice` — so the shared file is the preference and
/// `.preferred-me-source` is a derived artefact, never edited by hand.
enum MicPreference {

    /// The id meaning *let the ladder decide*. Never a device id.
    static let automatic = "auto"

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".walkie-talkie/mic")
    }

    static var url: URL { folder.appendingPathComponent("choice") }

    /// **What is on disk, or `auto`.** An id this app's roster does not know
    /// reads as `auto`: the two rosters are meant to be the same list, and on
    /// the day one app learns a device before the other, the older one should
    /// fall back to its ladder rather than tick nothing.
    static func read() -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return automatic }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return MicRoster.ids.contains(id) ? id : automatic
    }

    /// Publish a pick, atomically, so a reader woken by the write never sees a
    /// half-written id.
    static func write(_ id: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (id + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            overlayError("Mic: could not publish the choice '\(id)' — \(error)")
        }
    }

    // MARK: - Watching

    private static var source: DispatchSourceFileSystemObject?

    /// **Call `onChange` whenever Walkie Talkie rewrites the file.**
    ///
    /// A `DispatchSource` on the **folder**, not on the file: an atomic write
    /// replaces the inode, and a watch on the old descriptor stops firing after
    /// the first change. The folder is a dedicated one for exactly this reason —
    /// `~/.walkie-talkie/` itself has `relay.log` and `outbox.jsonl` being
    /// appended to constantly, and watching it would wake this app on every log
    /// line.
    ///
    /// Fires on this app's own writes too. That is deliberate rather than
    /// filtered: the handler's job is *make the menu agree with the file*, and
    /// doing that twice is free.
    static func watch(_ onChange: @escaping () -> Void) {
        stopWatching()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            overlayError("Mic: cannot watch \(folder.path) — Walkie Talkie's picks will not arrive")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { onChange() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    static func stopWatching() {
        source?.cancel()
        source = nil
    }
}
