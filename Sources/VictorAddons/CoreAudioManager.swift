import CoreAudio
import Foundation

class CoreAudioManager {
    static let dictationDeviceName = "🔊OS Output"
    static let dictationVolumeLow: Float = 0.01
    static let dictationMuteDelay: TimeInterval = 0.05

    private var isDictationActive = false
    private var originalVolume: Float = 1.0

    // Toggle mute: call from EventTapManager.onDictationMute callback
    func toggleDictationMute() {
        if isDictationActive {
            restoreVolume()
        } else {
            muteForDictation()
        }
    }

    private func muteForDictation() {
        guard let deviceID = findDeviceID(name: Self.dictationDeviceName) else {
            overlayInfo("WARNING: Device '\(Self.dictationDeviceName)' not found")
            return
        }
        originalVolume = getVolume(deviceID: deviceID)
        Thread.sleep(forTimeInterval: Self.dictationMuteDelay)
        setVolume(deviceID: deviceID, volume: Self.dictationVolumeLow)
        isDictationActive = true
        let fromPct = Int(originalVolume * 100)
        let toPct = Int(Self.dictationVolumeLow * 100)
        overlayInfo("🟢 Dictation: 🔇 OS Output (\(fromPct)%→\(toPct)%)")
    }

    private func restoreVolume() {
        guard let deviceID = findDeviceID(name: Self.dictationDeviceName) else {
            isDictationActive = false
            return
        }
        setVolume(deviceID: deviceID, volume: originalVolume)
        isDictationActive = false
        let pct = Int(originalVolume * 100)
        overlayInfo("🔴 Dictation: 🔊 OS Output (\(pct)%)")
    }

    // MARK: - CoreAudio helpers

    private func findDeviceID(name: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs)

        for deviceID in deviceIDs {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &cfName) { ptr in
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
            }
            if status == noErr, let raw = cfName {
                let str = raw.takeRetainedValue() as String
                if str == name { return deviceID }
            }
        }
        return nil
    }

    private func getVolume(deviceID: AudioObjectID) -> Float {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 1.0
        var size = UInt32(MemoryLayout<Float>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return volume
    }

    private func setVolume(deviceID: AudioObjectID, volume: Float) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = volume
        let size = UInt32(MemoryLayout<Float>.size)
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
    }
}
