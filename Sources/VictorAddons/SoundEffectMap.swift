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
        "23_radar.mp3":          "sonar",
    ]

    /// Effect to stop when a sound finishes / is stopped (looping effects only).
    static let onStop: [String: String] = [
        "15_flatline.mp3":       "pulse/stop",
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
