import AVFoundation
import Foundation

/// ＋ A video snippet made louder on disk (Victor, 2026-11-09) — without
/// touching the mp4.
///
/// The ＋ beside the tablet's per-tile bar asks Victor Effects
/// (`/sound/boost/video:<id>/up`), which owns every clip's boost and renders
/// the AUDIO of the played window (`startSeconds`, the 60 s auto-kill) louder,
/// from the original, through a −1 dBFS limiter, to a WAV of its own. The mp4
/// is never modified: the YouTube-publish guard fingerprints it, and a
/// re-encode would cost picture quality for a sound problem.
///
/// At play time this asks Effects for that render (`/sound/boost/video:<id>`,
/// a loopback call capped at `timeout`) and, when there is one, plays an
/// in-memory `AVMutableComposition`: the original's video track whole, its
/// original audio before and after the window, and the render inside it —
/// laid on the same timeline, so picture, subtitles, seeks and the ♪
/// soundtrack-only play all stay where they were. No render, Effects down, or
/// anything failing → the plain file, exactly as before.
enum VideoBoostAudio {
    /// Loopback: a refused connection answers at once, so this only ever bites
    /// when Effects is wedged — and then the clip plays un-boosted.
    static let timeout: TimeInterval = 0.3

    struct Render: Equatable { let path: String; let start: Double }

    /// `{"audio":{"path":…,"start":…}}` → the render; nil for `"audio":null`.
    static func parse(_ data: Data) -> Render? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let audio = obj["audio"] as? [String: Any],
              let path = audio["path"] as? String,
              let start = (audio["start"] as? NSNumber)?.doubleValue else { return nil }
        return Render(path: path, start: start)
    }

    /// The item to play for snippet `id`: the composition when Effects has a
    /// ready render for it, else the file itself.
    static func playerItem(id: String, fileURL: URL) -> AVPlayerItem {
        guard let data = EffectsProxy.fetch("/sound/boost/video:\(id)", timeout: timeout),
              let render = parse(data),
              FileManager.default.fileExists(atPath: render.path) else { return AVPlayerItem(url: fileURL) }
        do {
            let comp = try composition(original: fileURL, render: URL(fileURLWithPath: render.path), at: render.start)
            overlayInfo("＋ \(id): playing its louder audio (\(URL(fileURLWithPath: render.path).lastPathComponent)) over the untouched mp4")
            return AVPlayerItem(asset: comp)
        } catch {
            overlayError("＋ \(id): composition failed, playing the file as it is: \(error)")
            return AVPlayerItem(url: fileURL)
        }
    }

    enum Failure: Error { case noTrack(String) }

    /// The original's picture, with `render` replacing its audio from `start`
    /// for the render's length; the original audio before and after.
    static func composition(original: URL, render: URL, at start: Double) throws -> AVMutableComposition {
        let src = AVURLAsset(url: original, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let boosted = AVURLAsset(url: render, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let srcAudio = src.tracks(withMediaType: .audio).first else { throw Failure.noTrack("original audio") }
        guard let boostedAudio = boosted.tracks(withMediaType: .audio).first else { throw Failure.noTrack("render audio") }
        let comp = AVMutableComposition()
        let duration = src.duration
        for v in src.tracks(withMediaType: .video) {
            let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try t?.insertTimeRange(CMTimeRange(start: .zero, duration: v.timeRange.duration), of: v, at: .zero)
            t?.preferredTransform = v.preferredTransform
        }
        guard let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noTrack("composition audio")
        }
        let scale: CMTimeScale = 44100
        let s = CMTime(seconds: start, preferredTimescale: scale)
        let windowLength = min(boostedAudio.timeRange.duration, CMTimeSubtract(srcAudio.timeRange.end, s))
        let e = CMTimeAdd(s, windowLength)
        if s > .zero {
            try a.insertTimeRange(CMTimeRange(start: .zero, end: s), of: srcAudio, at: .zero)
        }
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: windowLength), of: boostedAudio, at: s)
        if e < srcAudio.timeRange.end {
            try a.insertTimeRange(CMTimeRange(start: e, end: srcAudio.timeRange.end), of: srcAudio, at: e)
        }
        _ = duration
        return comp
    }
}
