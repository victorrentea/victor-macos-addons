import CoreAudio
import Foundation

/// Where the lid-shut sounds go — the heartbeat, the 🫀 flatline and the sleep
/// tone: **the Mac's own speakers, whatever the default output is** (2026-10-07).
///
/// They used to follow the default output, and on 2026-10-07 the default was the
/// Sony WH-1000XM3: Victor shut the lid, the pulse beat 18 times into a pair of
/// headphones that were not on his head, and he heard nothing. A proof meant
/// for a bag has to come out of the machine in the bag. Bluetooth headphones or
/// speakers connected to it change nothing.
///
/// The volume boost and the mute lift follow the sound onto this device, and
/// the "something else is playing" veto only applies when it *is* the default
/// output: apps play to the default, so with the headphones as default the
/// built-in speaker is free to take to 100% without raising anybody's music.
///
/// No built-in output (never on a MacBook) → `nil` everywhere, which every
/// caller reads as "the default output", the old behaviour.
enum PulseOutput {

    static func device() -> AudioDeviceID? {
        BluetoothOutput.builtInOutputID()
    }

    /// For `AVAudioPlayer.currentDevice` / `NSSound.playbackDeviceIdentifier`.
    static func uid() -> String? {
        device().flatMap(BluetoothOutput.deviceUID)
    }

    static func name() -> String {
        device().map(BluetoothOutput.deviceName) ?? "default output"
    }

    /// Another app playing **on the device the pulse goes to** — the only music
    /// a boost could raise.
    static func otherAppPlaying() -> String? {
        if let device = device(), device != SystemOutputVolume.defaultOutputDevice() { return nil }
        return SystemAudioActivity.otherAppPlayingOutput()
    }
}
