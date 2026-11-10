import Foundation

/// 🥁 A sound this app needs rung, played as the **effects app's tile** it is.
///
/// The break gong is tablet tile #50, and "over and out" is #82. Played by the
/// effects app they get everything a press there gets: the tile's own visual
/// (the man striking the gong), the tile's bar, the tablet's blue wedge, the ＋
/// render, and the 🎚️ voice ceiling while Victor screen-shares — the volume is
/// decided in ONE place (Victor, 2026-11-10).
///
/// But "the break is over" must ring whatever else is running, so the effects
/// app is asked with a short timeout and, when it does not answer, `fallback`
/// plays the plain file here (`AddonSounds`) — no picture, the file's own level.
///
/// Not `/sound/pressed/<asset>` for the visual: that is a press by Victor, and
/// it would count in the tile's usage dots and the press log. `/effect/<name>`
/// draws the same picture without being one.
enum EffectTile {
    static let timeout: TimeInterval = 0.4

    /// Bumped by `stop`: a play still waiting for the effects app when the
    /// break watch is closed must not start a gong after the close.
    private static var generation = 0

    /// `/sound/play/<asset>`, then `/effect/<effect>` once the sound is accepted —
    /// the order of a press in `SoundboardPress`. Main thread in; `fallback` runs
    /// on the main thread.
    static func play(_ asset: String, effect: String? = nil, fallback: @escaping () -> Void) {
        let gen = generation
        DispatchQueue.global(qos: .userInteractive).async {
            let played = EffectsProxy.fetch(playPath(asset), timeout: timeout) != nil
            if played, let effect { EffectsProxy.fire("/effect/\(effect)") }
            DispatchQueue.main.async {
                if played {
                    overlayInfo("🥁 \(asset) played by the effects app\(effect.map { " with its '\($0)'" } ?? "")")
                    if gen != generation { stop(asset) {} }   // closed while it was being asked
                    return
                }
                guard gen == generation else { return }
                overlayInfo("🥁 \(asset): no answer from the effects app — played here, at its own level, without its picture")
                fallback()
            }
        }
    }

    /// Stops it wherever it is playing: the effects app's tile (sound and
    /// picture, with its interrupt fade) and the local copy (`localStop`).
    static func stop(_ asset: String, localStop: () -> Void) {
        generation += 1
        EffectsProxy.fire(stopPath(asset))
        localStop()
    }

    static func playPath(_ asset: String) -> String { "/sound/play/\(encode(asset))" }
    static func stopPath(_ asset: String) -> String { "/sound/stop/\(encode(asset))" }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
