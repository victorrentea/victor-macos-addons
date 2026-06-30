import Foundation

/// Single source of truth mapping a tablet sound file to the Mac overlay effect
/// it should trigger. The tablet no longer decides which sound drives which
/// effect — it just reports every press (`/sound/pressed/<file>`) and stop
/// (`/sound/stopped/<file>`), and the Mac looks the mapping up here. Change a
/// mapping (or add a brand-new effect) by editing this file and rebuilding the
/// Mac app — no tablet rebuild/redeploy needed.
///
/// The mapped strings are effect names understood by `AppDelegate`'s `onEffect`
/// switch (e.g. "explosion", "blood-drip", "rainbow/stop").
///
/// Note: `02_siren.mp3` is intentionally absent — the siren maps to the alarm
/// overlay (`/alarm/start`,`/alarm/stop`), a distinct toggled overlay with its
/// own lifecycle, and stays special-cased on the tablet.
enum SoundEffectMap {
    /// Effect to start when a sound button is pressed.
    static let onPress: [String: String] = [
        "03_explosion.mp3":      "explosion",
        "90_breaking-glass.mp3": "broken-glass",
        "59_game_over.mp3":      "game-over",
        "15_flatline.mp3":       "pulse",
        "27_clapping.mp3":       "applause",
        "13_heartbeat.mp3":      "heartbeat",
        "42_saxophone.mp3":      "spiral-hearts",
        "89_fireworks.mp3":      "fireworks",
        "08_scream_man.mp3":     "fear",
        "22_minigun.mp3":        "bullet-holes",
        "65_school_bell.mp3":    "fire-alarm",
        "10_red_phone.mp3":      "phone-ring",
        "19_fail.mp3":           "fail",
        "20_fail2.mp3":          "fail",
        "78_projector.mp3":      "sepia",
        "64_fbi.mp3":            "fbi-knock",
        "67_sfx_109.mp3":        "brother",
        "70_cavalry.mp3":        "cavalry",
        "29_gangnam_style.mp3":  "gangnam",
        "41_love_hearts.mp3":    "love-hands",
        "55_star_wars.mp3":      "star-wars",
        "37_rainbow.mp3":        "rainbow",
        "49_wrong.mp3":          "wrong-x",
        "50_gong.mp3":           "gong",
        "26_drum.mp3":           "drum-roll",
        "44_laugh_emoji.mp3":    "laugh",
        "40_joker.mp3":          "blood-drip",
        // Tile 34: a phoenix rises up the desktop with its cry. The tablet's
        // paired `34_phoenix.mp3` is silent; the real sound (`phoenix.mp3`) is a
        // Mac-owned resource played inside showPhoenix and faded out in unison
        // with the visual fade. The routed /sound/play path is neutralized in
        // onSoundPlay (like iris) so the silent clip isn't played.
        "34_phoenix.mp3":        "phoenix",
        // Tile 31 repurposed (was Tarzan): 🕳️ iris close. The paired mp3 keeps
        // its id "31_tarzan.mp3" for protocol/manifest stability but is now a
        // silent clip — the shrinking-circle blackout is the whole effect. A
        // second press toggles it back off (showIrisClose handles the cancel),
        // which is why it stays out of onSoundPlay's special cases (no
        // double-trigger).
        "31_tarzan.mp3":         "iris",
        // 23_radar.mp3 is NOT here: the Mac owns the radar SFX, so the sonar
        // effect is driven from the routed /sound/play path (onSoundPlay),
        // which plays the beep-synced audio itself — mapping the press too
        // would double-trigger it.
    ]

    /// Effect to stop when a sound finishes / is stopped (long-running effects:
    /// looping overlays, or emissions like spiral-hearts that otherwise keep
    /// spawning/lingering past the sound).
    static let onStop: [String: String] = [
        "15_flatline.mp3":       "pulse/stop",
        "42_saxophone.mp3":      "spiral-hearts/stop",
        "41_love_hearts.mp3":    "love-hands/stop",
        "37_rainbow.mp3":        "rainbow/stop",
        "67_sfx_109.mp3":        "brother/stop",
        "29_gangnam_style.mp3":  "gangnam/stop",
        "55_star_wars.mp3":      "star-wars/stop",
        "26_drum.mp3":           "drum-roll/stop",
        "59_game_over.mp3":      "game-over/stop",
    ]

    /// The effect name a pressed sound should start, or nil if the sound has no
    /// paired visual.
    static func pressEffect(for soundFile: String) -> String? { onPress[soundFile] }

    /// The effect name a stopped sound should stop, or nil.
    static func stopEffect(for soundFile: String) -> String? { onStop[soundFile] }
}
