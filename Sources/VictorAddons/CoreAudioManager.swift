import AppKit
import CoreAudio
import Foundation

class CoreAudioManager {
    private var isDictationActive = false
    private var dictationStartedAt: Date?
    // Dictation rarely lasts more than ~5 min; after 10 min assume the
    // pause-for-dictation flag is stale (e.g. media stopped on its own,
    // user closed the player) and clear it so the next Mouse 5 click
    // doesn't blindly resume audio that no longer exists.
    private let dictationStaleAfter: TimeInterval = 10 * 60

    // Toggle media pause/resume: call from EventTapManager.onDictationMute callback
    func toggleDictationMute() {
        expireStaleDictation()
        if isDictationActive {
            guard isMediaPlaying() else {
                isDictationActive = false
                dictationStartedAt = nil
                overlayInfo("🟡 Dictation: no audio running, cleared flag")
                return
            }
            resumeMedia()
        } else {
            pauseMedia()
        }
    }

    // Called on global ESC: if we paused media for dictation, Wispr was cancelled → resume.
    func resumeIfDictationActive() {
        expireStaleDictation()
        guard isDictationActive else { return }
        resumeMedia()
    }

    private func expireStaleDictation() {
        guard isDictationActive, let started = dictationStartedAt,
              Date().timeIntervalSince(started) > dictationStaleAfter else { return }
        isDictationActive = false
        dictationStartedAt = nil
        overlayInfo("🟡 Dictation flag expired (>10 min) — cleared")
    }

    private func pauseMedia() {
        guard isMediaPlaying() else {
            overlayInfo("🟡 Dictation: no media playing, skipping mute")
            return
        }
        postPlayPauseKey()
        isDictationActive = true
        dictationStartedAt = Date()
        overlayInfo("🟢 Dictation: ⏸ media paused")
    }

    // macOS 15+ locked down MediaRemote.framework so `nowplaying-cli get-raw` returns
    // "null" — instead, ask CoreAudio whether the default output device is currently
    // being driven by any process. True when Music, Spotify, a browser tab, etc. is
    // actively producing audio.
    private func isMediaPlaying() -> Bool {
        var deviceID = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let getDevice = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddr, 0, nil, &deviceSize, &deviceID)
        guard getDevice == noErr, deviceID != 0 else { return true }  // conservative

        var running = UInt32(0)
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        let getRunning = AudioObjectGetPropertyData(
            deviceID, &runningAddr, 0, nil, &runningSize, &running)
        guard getRunning == noErr else { return true }  // conservative
        return running != 0
    }

    private func resumeMedia() {
        postPlayPauseKey()
        isDictationActive = false
        dictationStartedAt = nil
        overlayInfo("🔴 Dictation: ▶ media resumed")
    }

    // NX_KEYTYPE_PLAY=16 — same signal the hardware Play/Pause key sends.
    // Works for YouTube in browsers, Spotify, Music, etc. — anything that
    // listens for the system media key. Replaces nowplaying-cli which is
    // broken on macOS 15+ because Apple locked down MediaRemote.framework.
    private func postPlayPauseKey() {
        let NX_KEYTYPE_PLAY: Int32 = 16
        for flagsDown in [0xA00, 0xB00] {
            let data1 = (Int(NX_KEYTYPE_PLAY) << 16) | flagsDown
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flagsDown)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
