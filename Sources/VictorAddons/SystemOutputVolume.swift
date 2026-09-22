import CoreAudio
import Foundation

/// Read and write the volume of **whatever the Mac is currently playing through**
/// — the default output device, not a device named in advance.
///
/// `CoreAudioManager` also moves a volume, but a different one and for a different
/// reason: it pushes the named `🔊OS Output` aggregate down to 1% so dictation is
/// not sung over. This one exists for `LidAwake`, whose heartbeat has to be *heard
/// through a closed bag*, and a heartbeat is only as loud as the device it comes
/// out of — which by then may be the built-in speakers, the JBLs or whatever
/// `OutputRouter` last handed the system.
///
/// **The mute switch is a second, independent knob** (`isMuted`/`setMuted`,
/// 2026-09-15). Muting a Mac does not move its volume — the device keeps
/// reporting the level it had — so a volume this class parks at 100% is still
/// 100% of nothing while the mute flag is up. `LidAwake` therefore has to lift
/// it as well, and put it back, which is why both halves live here.
///
/// **Not every device answers the master control.** Aggregates and some USB
/// interfaces expose no `VolumeScalar` on element 0 and only per-channel ones on
/// elements 1 and 2, so both are tried, in that order — and `nil`/`false` come
/// back when neither works, which the caller must treat as "leave the volume
/// alone" rather than as silence.
enum SystemOutputVolume {

    /// The device the system default output points at, or `nil` if it cannot be read.
    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr,
              id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// Current output volume as 0…1, or `nil` when the device has no readable one.
    static func get() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        for element in elements {
            var addr = address(element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var volume: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    /// Set the output volume, clamped to 0…1. Returns whether anything took.
    @discardableResult
    static func set(_ volume: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var wanted = min(1, max(0, volume))
        var wrote = false
        for element in elements {
            var addr = address(element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { continue }
            if AudioObjectSetPropertyData(device, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float>.size), &wanted) == noErr {
                wrote = true
                // The master control moves every channel at once; only when it is
                // absent do the per-channel ones have to be walked.
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return wrote
    }

    /// Is the default output **muted**? `nil` when the device exposes no mute
    /// control at all (plenty of Bluetooth and USB devices do not — macOS then
    /// mutes them by driving the volume to 0 instead).
    ///
    /// Mute is a separate property from the volume, and that is the whole
    /// reason this exists: a muted device still reports whatever
    /// `VolumeScalar` it had before, so `get()` answering `0.6` says nothing
    /// about whether a sound will be heard. `LidAwake` parking the output at
    /// 100% on a muted Mac is 100% of silence.
    static func isMuted() -> Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        for element in elements {
            var addr = muteAddress(element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return nil
    }

    /// Mute or unmute the default output. Returns whether anything took — the
    /// same "leave it alone" contract as `set`.
    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var wanted: UInt32 = muted ? 1 : 0
        var wrote = false
        for element in elements {
            var addr = muteAddress(element)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { continue }
            if AudioObjectSetPropertyData(device, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &wanted) == noErr {
                wrote = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return wrote
    }

    /// Master first, then left and right — see the note on the enum.
    private static let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }
}
