import Foundation

/// **Which device is allowed to carry the sound, and which one should.**
///
/// This is the whole decision half of `OutputRouter`; the manager beside it only
/// reads CoreAudio and writes the default output. It replaced
/// `BluetoothAutoOutputPolicy` on 2026-09-22 because two separate components
/// writing `kAudioHardwarePropertyDefaultOutputDevice` would have fought each
/// other on exactly the edges that matter — the JBL connecting while the Bose is
/// on his head is *one* situation, not two.
///
/// ## Two rules, deliberately kept apart
///
/// **`rescueTarget`** answers *this device must not be playing at all*. The DJI
/// Mic Mini is a lavalier: paired straight to the Mac over Bluetooth it comes up
/// as an HFP headset, so macOS publishes a one-channel **output** beside its
/// microphone and will happily route a meeting into a thing that has no speaker
/// in it. It did exactly that on 2026-09-22 — Victor: *"m-a amețit astăzi când
/// m-am dus într-o ședință și mi l-a luat ca și output device"* — and the two
/// minutes he then spent disconnecting the JBL looking for a new playback device
/// are the real cost. macOS offers no way to hide the endpoint, so the only
/// move left is to put the default back the instant it lands there.
///
/// **`takeoverTarget`** answers *of the things that can play, which should*. It
/// is the old JBL-appearance rule with a rank in front of it, because the
/// headset and the speakers are not peers: while the Bose is connected it is on
/// his head and the boxes are across the room.
///
/// ## Why the speakers are never disconnected
///
/// Victor asked for the boxes to *stay connected and silent* while the headset
/// is on, and for them to come back when it goes (*"când închid căștile, să
/// revină boxele ca și device de output default"*). That is what a ladder gives
/// for free: macOS plays to exactly one default output, so a connected JBL that
/// is not the default is already a silent one. Nothing here ever asks Bluetooth
/// to drop a device — a disconnect costs a reconnect, and a reconnect is the one
/// thing a Bluetooth speaker is bad at.
enum OutputRouterPolicy {

    /// **Ranked best first.** Case-insensitive substring, matched against
    /// CoreAudio's device name.
    ///
    /// The headset outranks the speakers for the reason above. Everything not
    /// on this list is *unranked*, which is not the same as last: an unranked
    /// device that Victor chose himself is never taken away from him — only an
    /// appearance edge or a vanished default moves the output at all.
    static let ladder: [String] = ["Bose", "JBL"]

    /// **Microphones macOS insists on publishing as outputs.** Never a target,
    /// and never allowed to keep the default.
    ///
    /// `DJI` catches both the Mic Mini transmitter paired over Bluetooth
    /// (`DJI Mic Mini-B83BBE`) and any sibling of the same line — they are all
    /// lavaliers and none of them has a speaker.
    static let neverOutput: [String] = ["DJI"]

    static func matches(_ name: String, _ needle: String) -> Bool {
        name.range(of: needle, options: .caseInsensitive) != nil
    }

    /// Must this device never carry playback?
    static func isBlocked(_ name: String) -> Bool {
        neverOutput.contains { matches(name, $0) }
    }

    /// Position on the ladder, or `nil` for a device that is on nobody's list.
    static func rank(_ name: String) -> Int? {
        ladder.firstIndex { matches(name, $0) }
    }

    /// The best-ranked device among `devices`, ignoring blocked ones.
    static func best(of devices: [String]) -> String? {
        devices
            .filter { !isBlocked($0) }
            .compactMap { name in rank(name).map { (name, $0) } }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: - Rule 1 — get off a device that cannot play

    /// **The default output landed on a microphone.** Where to put it instead.
    ///
    /// The ladder first, then `fallback` (the built-in speakers, which are the
    /// one output this Mac always has), then anything at all that is not
    /// blocked. `nil` means *leave it alone*: either the default is fine, or
    /// every output on this Mac is a blocked one and moving it would only
    /// swap one silent device for another.
    ///
    /// - Parameters:
    ///   - devices: every connected output device name, in CoreAudio's order.
    ///   - defaultOutput: what macOS has right now (`nil` if unreadable).
    ///   - fallback: the built-in speakers' name, if this Mac reported one.
    static func rescueTarget(devices: [String], defaultOutput: String?, fallback: String?) -> String? {
        guard let defaultOutput, isBlocked(defaultOutput) else { return nil }
        if let ranked = best(of: devices) { return ranked }
        if let fallback, !isBlocked(fallback), devices.contains(fallback) { return fallback }
        return devices.first { !isBlocked($0) }
    }

    // MARK: - Rule 2 — follow the ladder as devices come and go

    /// **A device appeared, or the one that was playing vanished.** Which
    /// device should hold the output now, or `nil` to change nothing.
    ///
    /// The trigger is a device-list edge, and only an edge, which is what keeps
    /// this from fighting a manual choice: once everything is connected,
    /// switching the output by hand to `🔊OS Output` or to the built-in speakers
    /// changes no device list, so nothing pulls it back. The seed snapshot at
    /// launch is likewise an edge we ignore (`OutputRouter` seeds `previous`
    /// with the current list), so relaunching the app never hijacks an output.
    ///
    /// Two edges act:
    ///
    /// 1. **Something ranked appeared** — take the output, but only for the
    ///    best-ranked device connected, and only if it beats whatever holds the
    ///    default now. So plugging the JBL in while the Bose is on his head
    ///    changes nothing, and connecting the Bose while the JBL is playing
    ///    moves the sound to his head.
    /// 2. **A ranked device disappeared** — hand the output to the best-ranked
    ///    survivor. This is the headset coming off, and it is deliberately
    ///    phrased as *the Bose left* rather than as *the default vanished*:
    ///    macOS reroutes a disappearing default to the built-in speakers on its
    ///    own, and whether it has already done so by the time this listener runs
    ///    is a race. Asking about the device that left instead of about the
    ///    default gives the same answer either way. (A vanished default that was
    ///    on nobody's list — a USB DAC unplugged — counts as the same edge.)
    ///
    /// - Parameters:
    ///   - previous: every output device name in the last snapshot.
    ///   - current: every output device name now.
    ///   - defaultOutput: what macOS has right now (`nil` if unreadable).
    static func takeoverTarget(previous: Set<String>, current: Set<String>,
                               defaultOutput: String?) -> String? {
        guard let target = best(of: Array(current).sorted()) else { return nil }
        if defaultOutput == target { return nil }  // already there

        let appeared = current.subtracting(previous)
        let vanished = previous.subtracting(current)
        let rankedAppeared = appeared.contains { rank($0) != nil && !isBlocked($0) }
        let rankedVanished = vanished.contains { rank($0) != nil && !isBlocked($0) }
        // The device that was playing is gone — either it was ranked (the
        // headset came off) or it was not (a DAC was unplugged).
        let defaultVanished = defaultOutput.map { vanished.contains($0) } ?? false

        if rankedAppeared {
            // Only climb. A JBL appearing under a connected Bose must not pull
            // the sound off his head, and a device he chose by hand that is not
            // on the ladder at all is left alone unless a ranked one arrives.
            guard let targetRank = rank(target) else { return nil }
            if let current = defaultOutput, let currentRank = rank(current), currentRank <= targetRank {
                return nil
            }
            return target
        }
        if rankedVanished || defaultVanished { return target }
        return nil
    }
}
