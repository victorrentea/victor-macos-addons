import Foundation

/// Latch policy for the "Wispr started but the system output is not the
/// monitored loopback" alert.
///
/// The music-mute feature only works when the macOS default output is
/// `🔊OS Output` (the Rogue Amoeba loopback the app taps and whose volume it
/// drops). When the default output drifts elsewhere (e.g. macOS resets it to
/// the built-in speakers after sleep), dictation no longer ducks the music.
///
/// `evaluate` is called on each Wispr-start. It alerts **once** per drift
/// episode and re-arms the moment a Wispr-start sees the correct output again,
/// so the user is warned without being spammed on every dictation.
enum OutputDriftPolicy {
    static let monitored = "🔊OS Output"

    /// - Parameters:
    ///   - output: current default-output device name (`nil` if unreadable).
    ///   - alerted: whether we've already warned since the last correct output.
    /// - Returns: `alert` — show the notification now; `alerted` — next latch state.
    static func evaluate(output: String?, alerted: Bool) -> (alert: Bool, alerted: Bool) {
        guard let output else { return (false, alerted) }   // unknown → do nothing
        if output == monitored { return (false, false) }    // correct → re-arm
        if alerted { return (false, true) }                 // wrong, already warned
        return (true, true)                                 // wrong, first time → alert
    }
}
