import CoreAudio
import Foundation

class MeetingDetector {
    var onMeetingChanged: ((Bool) -> Void)?

    private var deviceID: AudioObjectID = kAudioObjectUnknown
    private var isMeetingActive = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        deviceID = findDevice(named: "🎙️TO Zoom")
        guard deviceID != kAudioObjectUnknown else {
            overlayInfo("MeetingDetector: '🎙️TO Zoom' device not found")
            return
        }
        registerListener()
    }

    func checkInitialState() {
        refreshState()
    }

    deinit {
        guard deviceID != kAudioObjectUnknown, let block = listenerBlock else { return }
        var address = runningSomewhereAddress()
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.global(), block)
    }

    private func findDevice(named targetName: String) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &ids)
        return ids.first { deviceName(for: $0) == targetName } ?? kAudioObjectUnknown
    }

    private func deviceName(for id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name as String
    }

    private func registerListener() {
        var address = runningSomewhereAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshState() }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.global(), block)
    }

    private func refreshState() {
        var address = runningSomewhereAddress()
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        let active = isRunning != 0
        guard active != isMeetingActive else { return }
        isMeetingActive = active
        overlayInfo("MeetingDetector: meeting \(active ? "started" : "ended")")
        onMeetingChanged?(active)
    }

    private func runningSomewhereAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
