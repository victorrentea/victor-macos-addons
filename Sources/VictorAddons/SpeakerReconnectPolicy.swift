import Foundation

/// The decisions behind `SpeakerReconnect`, pure so they can be pinned by
/// `SpeakerReconnectPolicyTests` without a radio.
///
/// **Why it exists** (2026-10-01): Victor carries two JBL boxes so that one
/// dying is not the end of the sound. But only one of them was ever connected
/// to the Mac — the other one sat powered on, in standby, waiting for a source
/// that never came, and a JBL left without a source switches itself off after
/// ~20 minutes. So when the connected one died the spare was already gone too,
/// and the soundboard fell through to the laptop speakers. A spare only works
/// if the Mac holds it: connect every JBL box that is on, so `OutputRouter`
/// has a survivor to hand the output to (its "a ranked device vanished" rule)
/// and `victor-effects`' keep-alive has a device to keep awake.
enum SpeakerReconnectPolicy {
    /// How long after the last box went away the Mac keeps looking for one.
    /// Not forever: at home, with both boxes in a drawer, paging two absent
    /// speakers every 30 s all evening is radio time for nothing.
    static let graceAfterLoss: TimeInterval = 15 * 60
    /// Paging cadence per absent box while another one is connected — the room
    /// has sound, so this only arms the spare. Each page takes the radio for
    /// up to ~15 s, which is why this is not 30 s too.
    static let whileCovered: TimeInterval = 3 * 60
    /// …and while none is: the room just went silent, look hard.
    static let whileUncovered: TimeInterval = 30

    /// A JBL **loudspeaker**, by its Bluetooth class of device: major Audio
    /// (0x04), minor Loudspeaker (0x05). The class is what keeps the
    /// "JBL TUNE500BT" headphones (minor 0x01, headset) off the list — the
    /// name alone would match them, and connecting a headset nobody is wearing
    /// would let `OutputRouter` hand it the room's sound.
    static func isSpeaker(name: String, major: UInt32, minor: UInt32) -> Bool {
        major == 0x04 && minor == 0x05 && OutputRouterPolicy.matches(name, "JBL")
    }

    /// Page this absent box now?
    ///
    /// - Parameters:
    ///   - anyConnected: is some other JBL box connected right now?
    ///   - lastSeenConnected: the last time any box was, `nil` if never since
    ///     launch — which keeps the Mac from hunting for speakers it was not
    ///     using in the first place.
    ///   - lastAttempt: the last page of *this* box, `nil` if never.
    static func shouldPage(anyConnected: Bool, lastSeenConnected: Date?,
                           lastAttempt: Date?, now: Date) -> Bool {
        if !anyConnected {
            guard let seen = lastSeenConnected,
                  now.timeIntervalSince(seen) <= graceAfterLoss else { return false }
        }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= (anyConnected ? whileCovered : whileUncovered)
    }
}
