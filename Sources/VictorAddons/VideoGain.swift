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
/// Same curve as the tiles: slider position 0…100, x², pinned at 80 → ×1.0
/// (40 → ×0.25). Above 80 a tile is boosted by a pre-amplified copy; an
/// `AVPlayer` has no such copy and its volume stops at 1.0, so for a video the
/// top of the bar is simply full volume.
enum VideoGain {
    static let defaultPct = 80
    static let keyPrefix = "video:"

    /// Bar position → `AVPlayer.volume`. Nil (no `?gain=`) = the old fixed 1.0.
    static func volume(position: Int?) -> Float {
        guard let position else { return 1 }
        let p = Float(max(0, min(100, position))) / Float(defaultPct)
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
