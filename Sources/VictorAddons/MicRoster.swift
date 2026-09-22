import Foundation

/// **The microphones Victor names by their picture**, and the one list this app
/// draws its mic menu from.
///
/// It is deliberately a **copy of `InputDevice.known` in `walkie-talkie`**, row
/// for row, glyph for glyph, in the same order — the two apps show the same
/// five-or-six rows for the same hardware, and Victor asked for the two menus
/// to look the same and to stay in step (*"the menu should look the same … when
/// I change it in one, it should change it to the other automatically"*, plus
/// `MicPreference` for the sync itself).
///
/// **Why copied rather than shared.** Walkie Talkie is public and this repo is
/// private, and the standing rule is that Walkie must stay usable without it —
/// so nothing may make the public app depend on this one. The shared `victor-mac-kit`
/// package could hold the list, but it would not save the *third* copy, which is
/// the one that actually resolves devices: this app does not open the microphone
/// in Swift at all. `whisper-transcribe/whisper_runner.py` does, and it matches
/// on its own `_ME_PATTERNS` / `_DEVICE_SHORT_NAMES`. So the honest shape is
/// three copies kept in step by one test (`MicRosterTests`, which reads the
/// Python file) rather than an abstraction that covers two of the three.
///
/// ## The order is the preference
///
/// One array is the menu's rows top to bottom **and** the ladder the Python
/// resolver walks for *automatic* — a menu whose order disagreed with the
/// automatic pick would teach the wrong thing every time it is opened. Victor's
/// order (2026-09-19): *"the preference of mic to use is: XLR>DJI>BOSE>MAC"*.
/// It is a quality ranking, not a convenience one: the XLR on his desk is a
/// condenser through a preamp, the DJI is a lavalier on his collar, the Bose is
/// a headset, and the built-in is two feet away across a desk with a projector
/// fan in the room.
///
/// **The speakerphone moved down on 2026-09-22.** It used to be second here,
/// above the XLR, on the reading that a far-field room mic with AGC beats a
/// condenser pointed at one chair in a hall. That reasoning is still written
/// down; the rank is not, because the ladder now has to be the same ladder in
/// both apps and Victor's order is the one he stated. It sits below the two
/// lavaliers — they are on his collar wherever he walks — and above the headset.
enum MicRoster {

    /// - `id`: the token written to `~/.walkie-talkie/mic/choice`, shared with
    ///   Walkie Talkie. **These strings are a contract between two apps.**
    /// - `glyph`: the emoji, which is also what `whisper_runner.py` emits on
    ///   `VICTOR_SOURCE:` / `VICTOR_AVAILABLE:` — the Python short name and the
    ///   menu's picture are the same character on purpose, so nothing has to
    ///   translate between them.
    /// - `short`: for the **parent** row, read out of the corner of the eye
    ///   while the menu is open over his work.
    /// - `label`: for the row under the arrow, where *which device exactly* is
    ///   actually being asked.
    /// - `pattern`: what goes into `.preferred-me-source` for the Python side —
    ///   a substring of the CoreAudio device name, and an entry of
    ///   `_ME_PATTERNS`.
    struct Mic {
        let id: String
        let glyph: String
        let short: String
        let label: String
        let pattern: String
    }

    static let all: [Mic] = [
        Mic(id: "xlr",   glyph: "🎙️", short: "XLR",    label: "Elgato Wave XLR",
            pattern: "XLR"),
        // **The dish is the receiver and the microphone is the microphone**
        // (2026-09-22, Victor: *"use mic icon instead of sattelite"*). The two
        // were the other way round for the few hours the transmitter existed,
        // which had the collar-worn capsule drawn as a satellite dish and the
        // USB-C dongle drawn as a microphone — backwards on both counts, and
        // the reason the two rows were hard to tell apart at a glance.
        Mic(id: "rx",    glyph: "📡",  short: "DJI Rx", label: "DJI Wireless Mic Rx",
            pattern: "Wireless Mic"),
        // The same lavalier with the receiver left in the bag: a Mic Mini
        // transmitter pairs straight to the Mac over Bluetooth and shows up as
        // `DJI Mic Mini-XXXXXX`. One rung below the receiver — same capsule on
        // the same collar, but the headset profile hands over 16 kHz mono while
        // the receiver on USB-C hands over 48 kHz.
        Mic(id: "tx",    glyph: "🎤",  short: "DJI TX", label: "DJI Mic Mini (Bluetooth)",
            pattern: "DJI Mic"),
        Mic(id: "stage", glyph: "🏛️", short: "Stage",  label: "Stage Speakerphone",
            pattern: "Room Speakerphone"),
        Mic(id: "bose",  glyph: "🎧",  short: "Bose",   label: "Bose",
            pattern: "Bose"),
        Mic(id: "mac",   glyph: "💻",  short: "MacBook", label: "MacBook Pro Microphone",
            pattern: "MacBook"),
    ]

    static let ids: [String] = all.map(\.id)

    /// The ladder spelled with the glyphs, for the `Automatic` row — the menu
    /// says what automatic *does* rather than asking him to remember it.
    static var ladder: String { all.map(\.glyph).joined(separator: " ▸ ") }

    static func byId(_ id: String) -> Mic? { all.first { $0.id == id } }
    static func byGlyph(_ glyph: String) -> Mic? { all.first { $0.glyph == glyph } }
    static func byPattern(_ pattern: String) -> Mic? { all.first { $0.pattern == pattern } }
}
