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
/// `BluetoothAutoOutput` last handed the system.
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

    /// Master first, then left and right — see the note on the enum.
    private static let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

    private static func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }
}
