import Foundation

/// 🔉 Each video snippet's own volume — the tablet's per-tile bar, now on page 2
/// too (Victor, 2026-11-03: "volumul pe efect să fie disponibil și pentru
/// videourile de pe pagina doi").
///
/// **The table is not kept here.** Victor Effects owns every tile's volume
/// (`SoundGains`, `sound-gains.json`) and a video is just one more row, keyed
/// `video:<id>` — so it persists, reaches the tablet through `gainsHash` and is
/// read by the Mac panel's 🎬 page without a second store to keep in step. This
/// app only *plays* the clip, so it learns the level two ways, neither of which
/// waits on the effects app:
///
/// - **at play time**, as `?gain=<pct>` on `/video/play/<id>` and
///   `/video/sound/<id>` (the tablet and the panel both send it);
/// - **live**, by noticing `/sound/gain/video:<id>/<pct>` on its way through
///   the proxy (`parseGainPath`), while the clip is still playing.
///
/// Same curve as the tiles: slider position 0…80, x², 80 → ×1.0 = the clip
/// as stored, shown on the tablet as "100%" (40 → ×0.25). **Down only since
/// 2026-11-09**, like every tile: nothing plays above ×1 at runtime. A quiet
/// snippet is made louder ON DISK by the ＋ beside the bar instead — Effects
/// renders its played window's audio louder and `VideoBoostAudio` lays it over
/// the untouched mp4.
enum VideoGain {
    static let defaultPct = 80
    static let keyPrefix = "video:"

    /// Bar position → `AVPlayer.volume`. Nil (no `?gain=`) = the old fixed 1.0.
    static func volume(position: Int?) -> Float {
        guard let position else { return 1 }
        let p = Float(max(0, min(defaultPct, position))) / Float(defaultPct)
        return min(1, p * p)
    }

    /// `/sound/gain/video:<id>/<pct>` → (id, pct); nil for any other path,
    /// including an ordinary tile's gain.
    static func parseGainPath(_ path: String) -> (id: String, pct: Int)? {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let prefix = "/sound/gain/"
        guard pathOnly.hasPrefix(prefix) else { return nil }
        let parts = pathOnly.dropFirst(prefix.count).split(separator: "/")
        guard parts.count == 2, let pct = Int(parts[1]) else { return nil }
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        guard key.hasPrefix(keyPrefix) else { return nil }
        let id = String(key.dropFirst(keyPrefix.count))
        return id.isEmpty ? nil : (id, pct)
    }
}

/// 🎚️ A video played here is held under Victor's voice during a screen share,
/// exactly like an effect: the effects app owns the formula and the clip's
/// measured loudness (`video:<id>` in its loudness table), so this asks it —
/// `GET /voice/ceiling?key=video:<id>&volume=<v>` — at play time, with a short
/// timeout. No answer (effects down, slow) = the clip plays at its own level,
/// logged. The cap is remembered per clip, so a live move of its bar stays under it.
enum VideoCeiling {
    static let timeout: TimeInterval = 0.4
    private static var maxVolume: [String: Float] = [:]

    /// The parsed answer: the volume to play at, the ceiling, the dB taken off.
    static func parse(_ json: Data) -> (volume: Float, maxVolume: Float?, takenDb: Double)? {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let v = (o["volume"] as? NSNumber)?.floatValue else { return nil }
        return (v, (o["maxVolume"] as? NSNumber)?.floatValue, (o["takenDb"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// `asked`, or less while sharing. Main thread (the play handlers).
    static func volume(id: String, asked: Float, sharing: Bool) -> Float {
        maxVolume[id] = nil
        guard sharing else { return asked }
        let key = "video:\(id)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "video:\(id)"
        guard let data = EffectsProxy.fetch("/voice/ceiling?key=\(key)&volume=\(asked)", timeout: timeout),
              let r = parse(data) else {
            overlayInfo("🎚️ video \(id): no answer from the effects app — played at its own level \(asked)")
            return asked
        }
        maxVolume[id] = r.maxVolume
        let out = min(asked, r.volume)
        overlayInfo(String(format: "🎚️ video %@: vol %.2f → %.2f%@", id, asked, out,
                           r.takenDb > 0 ? String(format: " (capped −%.1f dB under the voice)", r.takenDb) : " (under the voice)"))
        return out
    }

    /// A live move of the clip's bar, kept under the cap it started with.
    static func live(id: String, asked: Float) -> Float {
        maxVolume[id].map { min(asked, $0) } ?? asked
    }
}
