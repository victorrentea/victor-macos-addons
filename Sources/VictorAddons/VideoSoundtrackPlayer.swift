import AVFoundation
import Foundation

/// 🎵 Plays a video snippet's **soundtrack alone** — no window, no projector,
/// nothing on screen — for a few seconds, so the room *remembers* a clip
/// instead of watching it again.
///
/// This is the ♪ button in the corner of every tile on the tablet's video page.
/// The whole point is that it does **not** interrupt what is on the projected
/// screen: a snippet everyone has already seen only needs its jingle to land
/// the callback, and stopping the deck to replay 90 seconds of video costs far
/// more than the joke is worth. So it deliberately does *not* go through
/// `VideoPlayer` / IINA — there is no player window to place, fullscreen, or
/// kill, and the presentation underneath never loses focus.
///
/// Three rules it owns, none of which the caller has to remember:
///
/// 1. **Never longer than `maxSeconds`.** A soundtrack running under a talk is
///    a distraction the moment it stops being a reference, and the tablet's
///    video page stays locked while it plays — so the cap is what guarantees
///    the board finds its way home even if nobody presses anything again.
/// 2. **One at a time, and a second press stops it.** A new play preempts the
///    current one (same semantics as the soundboard's routed sounds), and
///    `VideoPlayer` stops us before it launches a real clip — the video brings
///    its own audio, and hearing both is the one outcome nobody wants.
/// 3. **It fades, never cuts.** Same reasoning as `SoundManager.interruptFade`:
///    in a quiet room an abrupt `pause()` is a hard edge everybody hears, and
///    the silence lands harder than the sound did.
///
/// 💬 **Its `.srt` lines, karaoke-style, when ✓ Subtitles is on** (Victor,
/// 2026-11-12). There is no window here to burn them into, so the cues of the
/// play window go to Victor Effects (`/caption/video/<id>?cues=…`), whose
/// caption overlay sings them at the bottom of the glass like a soundboard
/// press. Fire-and-forget: the effects app down means no subtitle, never a
/// later or quieter soundtrack.
final class VideoSoundtrackPlayer {
    static let shared = VideoSoundtrackPlayer()

    /// Hard cap on a soundtrack-only play. Victor's own number: long enough to
    /// carry the punchline of any snippet on the board, short enough that a
    /// forgotten press cannot sit under a sentence he is still saying.
    static let maxSeconds: TimeInterval = 10
    /// How long the tail takes to die away, at the cap and on an interrupt.
    static let fadeSeconds: TimeInterval = 0.35

    /// AVPlayer rather than AVAudioPlayer: these are H.264/AAC **mp4s** (see
    /// `add-training-video`), and AVAudioPlayer refuses a container with a video
    /// track in it. With no layer and no output attached, AVPlayer is simply an
    /// audio player that happens to be able to read them.
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var fadeWork: DispatchWorkItem?
    private var stopWork: DispatchWorkItem?
    /// Players that are mid-fade and no longer reachable from `player`. They sit
    /// here purely so ARC does not deallocate them: a released AVPlayer stops
    /// dead, which is the exact hard cut the fade exists to avoid (the same trap
    /// `SoundManager.fadingOut` exists for). Drained as each fade finishes.
    private var fadingOut: [AVPlayer] = []

    /// Id of the snippet whose soundtrack is playing, or nil. The tablet keeps
    /// its own copy to light the ♪ button; this one is what makes a second
    /// request for the same id readable as a toggle from anywhere else.
    private(set) var playingId: String?
    /// When the cap will have silenced it. The tablet drains the ring on the
    /// tile over this, and `GET /video/state` reports what is left of it.
    private(set) var deadline: Date?
    /// The snippet whose words were sent to Victor Effects, so a stop from
    /// outside can take them down with the sound.
    private var captionedId: String?

    private init() {}

    var isPlaying: Bool { player != nil }

    /// Read-only snapshot for `GET /test/video/sound` — `rate` above zero is the
    /// only proof from outside the process that the audio pipeline actually ran
    /// (the loopback meter behind `/test/audio/playing` only sees the aggregate
    /// device, so it reads silent whenever the output is the laptop's own
    /// speakers or the JBLs).
    func stateJSON() -> String {
        let rate = player?.rate ?? 0
        let id = playingId.map { "\"\($0)\"" } ?? "null"
        let remaining = isPlaying ? (deadline.map { max(0, Int($0.timeIntervalSinceNow * 1000)) } ?? 0) : 0
        return "{\"playing\":\(isPlaying),\"kind\":\"sound\",\"id\":\(id),\"remainingMs\":\(remaining)," +
               "\"rate\":\(rate),\"volume\":\(player?.volume ?? 0),\"maxSeconds\":\(Int(Self.maxSeconds))}"
    }

    /// Start (or replace) the soundtrack of `fileURL` at `startSeconds`.
    /// Returns how many milliseconds it is scheduled to run — which is what the
    /// tablet holds its page open for — or nil if the file isn't there.
    ///
    /// Main thread only (AVPlayer + the timers below); every caller is an HTTP
    /// handler, which `TabletHttpServer` already runs inside `DispatchQueue.main.sync`.
    @discardableResult
    func play(id: String, fileURL: URL, startSeconds: Int, volume: Float = 1) -> Int? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            overlayError("VideoSoundtrackPlayer: file not found: \(fileURL.path)")
            return nil
        }
        // Replace, don't layer: a second snippet's soundtrack over the first is
        // noise, not a callback. Its words are replaced by the new track (or
        // end themselves), and a stop racing the new track could take that down.
        end(fade: false)

        // ＋ The same louder audio the clip plays with (`VideoBoostAudio`).
        let item = VideoBoostAudio.playerItem(id: id, fileURL: fileURL)
        let p = AVPlayer(playerItem: item)
        p.volume = volume   // 🔉 the clip's own bar (`VideoGain`)
        p.actionAtItemEnd = .pause
        // A clip whose remaining audio is shorter than the cap ends by itself;
        // no fade there, the material already ran out.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.end(fade: false)
        }
        // The words, sent the moment the audio starts so their clock is the
        // room's. Built now, on the main thread; the seek lands elsewhere.
        let wordsPath = VideoPlayer.subtitlesOn
            ? VideoPlayer.sidecarSubtitle(for: fileURL).flatMap {
                Self.captionPath(id: id, cues: SRTSubtitles.parse(file: $0), startSeconds: Double(max(0, startSeconds)))
            }
            : nil
        captionedId = wordsPath == nil ? nil : id

        // Exact seek (zero tolerance) for the same reason the tile thumbnail is
        // cut exactly: the manifest's start second IS the joke, and a keyframe
        // snap can land a scene away from it. Play only once the seek lands, so
        // the first thing heard is the right moment rather than the lead-in.
        p.seek(
            to: CMTime(seconds: Double(max(0, startSeconds)), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak p] _ in
            guard let p else { return }   // replaced before the seek landed
            p.play()
            if let wordsPath { EffectsProxy.fire(wordsPath) }
        }

        player = p
        playingId = id
        scheduleCap()
        overlayInfo("VideoSoundtrackPlayer: 🎵 \(fileURL.lastPathComponent) from \(startSeconds)s (max \(Int(Self.maxSeconds))s)")
        return Int(Self.maxSeconds * 1000)
    }

    /// 🔉 The tablet moved this snippet's volume bar while it sounds. Ignored
    /// mid-fade-out (the player is then in `fadingOut`): the fade is already
    /// taking it to silence, and its timer would overwrite this anyway.
    func setVolume(_ volume: Float, forId id: String) {
        guard playingId == id, let player, !fadingOut.contains(where: { $0 === player }) else { return }
        player.volume = volume
    }

    /// Silence it now. `fade` is false only when there is nothing left to soften
    /// — the clip ended on its own, or we are being replaced by a play that is
    /// about to start half a millisecond later.
    ///
    /// A stop from outside (a second press, stop-all, a real clip starting)
    /// takes its words down too; an end of its own (the cap, the clip running
    /// out) leaves the last line its second to be read — every line ends itself.
    func stop(fade: Bool = true) {
        if let id = captionedId {
            EffectsProxy.fire("/caption/video/\(Self.pathSafe(id))/stop")
        }
        end(fade: fade)
    }

    /// Silence it, the words left to end themselves.
    private func end(fade: Bool) {
        captionedId = nil
        fadeWork?.cancel(); fadeWork = nil
        stopWork?.cancel(); stopWork = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        guard let p = player else { playingId = nil; deadline = nil; return }
        player = nil
        playingId = nil
        deadline = nil
        guard fade, p.rate > 0 else {
            p.pause()
            return
        }
        fadeOutAndPause(p)
    }

    /// The cap, in two halves: start fading `fadeSeconds` before the deadline so
    /// the sound is *gone* at the deadline rather than chopped off at it.
    private func scheduleCap() {
        let fadeAt = max(0, Self.maxSeconds - Self.fadeSeconds)
        let fade = DispatchWorkItem { [weak self] in
            guard let self, let p = self.player else { return }
            self.fadeOutAndPause(p)
        }
        let atCap = DispatchWorkItem { [weak self] in self?.end(fade: false) }
        fadeWork = fade
        stopWork = atCap
        deadline = Date().addingTimeInterval(Self.maxSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAt, execute: fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxSeconds, execute: atCap)
    }

    // MARK: - 💬 Subtitles

    /// The cues heard in the play window, `startSeconds` to the cap, on the
    /// clock of the soundtrack (0 = its first sound): a line already under way
    /// at the start is cut to what is left of it; one starting past the cap,
    /// or so close to it that its fill would race the fade, is not sent.
    static func window(_ cues: [SRTSubtitles.Cue], startSeconds: Double,
                       maxSeconds: TimeInterval = maxSeconds) -> [(at: Double, end: Double, text: String)] {
        cues.compactMap { cue in
            let at = cue.start - startSeconds, end = cue.end - startSeconds
            guard end > 0.2, at < maxSeconds - fadeSeconds else { return nil }
            return (at: max(0, at), end: min(end, maxSeconds), text: cue.text)
        }
    }

    /// `/caption/video/<id>?cues=<json>` for Victor Effects, or nil when the
    /// window has no words.
    static func captionPath(id: String, cues: [SRTSubtitles.Cue], startSeconds: Double) -> String? {
        let heard = window(cues, startSeconds: startSeconds)
        guard !heard.isEmpty else { return nil }
        let rows = heard.map { ["at": ($0.at * 1000).rounded() / 1000, "end": ($0.end * 1000).rounded() / 1000, "text": $0.text] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let json = String(data: data, encoding: .utf8) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = json.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "/caption/video/\(pathSafe(id))?cues=\(encoded)"
    }

    /// A YouTube id is already URL-safe; this only guards a hand-made one.
    static func pathSafe(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? id
    }

    /// Ramp `player`'s volume to zero and pause it. AVPlayer has no `setVolume(_:fadeDuration:)`
    /// of its own (that is AVAudioPlayer), and an AVAudioMix ramp would have to
    /// be installed before playback starts — so the ramp is stepped by hand. The
    /// player is captured by the timer, which keeps it alive through the fade
    /// even though `stop()` has already let go of it.
    private func fadeOutAndPause(_ p: AVPlayer) {
        if !fadingOut.contains(where: { $0 === p }) { fadingOut.append(p) }
        let steps = 20
        let interval = Self.fadeSeconds / Double(steps)
        let startVolume = p.volume
        var step = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            step += 1
            p.volume = startVolume * Float(max(0, steps - step)) / Float(steps)
            if step >= steps {
                t.invalidate()
                p.pause()
                self?.fadingOut.removeAll { $0 === p }
            }
        }
    }
}
