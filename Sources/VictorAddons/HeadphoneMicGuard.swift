import CoreAudio

/// **The Sony WH-1000XM3 is never the microphone.**
///
/// Victor (2026-09-23): *"căștile WH conectate acum se aud ca și cum ar avea
/// microfonul conectat — să nu se mai întâmple asta niciodată"*. A Bluetooth
/// headset has one radio link for two profiles: A2DP (stereo, 44.1/48 kHz,
/// output only) and HFP (mono, 16 kHz, output *and* mic). The moment anything
/// opens the headset's mic, the whole link drops to HFP and the music turns
/// into a phone call. macOS makes that likely by promoting a freshly connected
/// headset to *default input* — found that way today, both halves at 16 kHz.
///
/// So whenever the system default input lands on a banned headset, it is moved
/// to the best other microphone: the `MicRoster` ladder first (XLR ▸ DJI ▸ …),
/// then whatever else has input channels. With no app holding the headset's
/// mic any more, macOS puts the link back on A2DP by itself.
///
/// **What it cannot stop:** an app that picks the headset mic *by name*
/// (Teams/Zoom set to "WH-1000XM3" instead of "System default") opens it
/// directly and forces HFP regardless of the default. Those settings are per
/// app; this guard only owns the system default.
///
/// Driven by `MicSourceAnnouncer`, which already listens to the default input
/// and the device list — a second pair of listeners would just race it.
enum HeadphoneMicGuard {

    /// Substrings of CoreAudio device names that must never be the default input.
    /// `WH-1000X` covers the XM3 and its successors.
    static let banned = ["WH-1000X"]

    static func isBanned(_ name: String) -> Bool {
        banned.contains { name.localizedCaseInsensitiveContains($0) }
    }

    /// The input to switch to when `current` is banned, or nil when it is not
    /// (or there is nothing else to switch to). Pure, so the choice is testable.
    static func replacement(current: String, inputs: [String]) -> String? {
        guard isBanned(current) else { return nil }
        let allowed = inputs.filter { !isBanned($0) }
        for mic in MicRoster.all {
            if let hit = allowed.first(where: { $0.contains(mic.pattern) }) { return hit }
        }
        return allowed.first
    }

    /// Move the default input off a banned headset. Returns whether it moved
    /// it — the move itself fires `DefaultInputDevice`, so the announcer will
    /// settle again and announce the replacement.
    @discardableResult
    static func enforce() -> Bool {
        let currentId = MicSourceAnnouncer.defaultInputId()
        guard let current = MicSourceAnnouncer.name(of: currentId) else { return false }
        let inputs = inputDevices()
        guard let target = replacement(current: current, inputs: inputs.map(\.name)),
              let targetId = inputs.first(where: { $0.name == target })?.id else {
            if isBanned(current) { overlayError("🎧 \(current) is the default input and there is no other mic to move to") }
            return false
        }
        guard setDefaultInput(targetId) else {
            overlayError("🎧 Could not move default input off \(current) to \(target)")
            return false
        }
        overlayInfo("🎧 \(current) was the default input → moved to \(target) (keeps the headset on A2DP)")
        return true
    }

    // MARK: - CoreAudio

    private static func inputDevices() -> [(id: AudioDeviceID, name: String)] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty, AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInputChannels(id), let name = MicSourceAnnouncer.name(of: id) else { return nil }
            return (id, name)
        }
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }
}
