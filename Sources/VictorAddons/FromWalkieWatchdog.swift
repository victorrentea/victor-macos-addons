import AppKit
import CoreAudio
import Foundation

/// What the watchdog does on one tick.
///
/// **One-way, like 🛰️ Claude RC's tick**: it only ever turns the device *off*.
/// Turning it on is Walkie Talkie's job at launch — a watchdog that also switched it
/// on would make "From Walkie" exist without the relay feeding it, which is the
/// silent microphone this whole thing is there to prevent.
enum FromWalkieWatchdogPolicy {
    static func shouldTurnOff(walkieRunning: Bool, deviceOn: Bool) -> Bool {
        deviceOn && !walkieRunning
    }
}

/// 🎚️ Turns the **"From Walkie"** microphone off when Walkie Talkie is not running
/// (2026-09-29).
///
/// "From Walkie" is a BlackHole-built pass-through device (`../from-walkie`) the relay
/// plays into and Wispr Flow listens to. Walkie turns it on at launch and off at
/// quit; a crash or a `kill -9` skips the quit, and then Wispr would sit on a
/// present-but-silent microphone instead of falling back to the next one in its
/// ranking. So this polls every 5 s and switches the device off — through the
/// driver's `kAudioBoxPropertyAcquired`, no GUI, no sudo.
///
/// A Mac without the driver has no box: every tick is a no-op.
final class FromWalkieWatchdog {
    static let pollInterval: TimeInterval = 5
    static let walkieBundleID = "ro.victorrentea.wispr-relay"  // Walkie Talkie's TCC identity, never renamed
    static let boxUID = "FromWalkie_UID"

    private let queue = DispatchQueue(label: "ro.victorrentea.from-walkie-watchdog")
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let box = Self.box() else { return }
        let walkieRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.walkieBundleID).isEmpty
        guard FromWalkieWatchdogPolicy.shouldTurnOff(walkieRunning: walkieRunning, deviceOn: Self.isOn(box)) else { return }
        let err = Self.set(box, on: false)
        overlayInfo(err == noErr
            ? "🎚️ From Walkie off — Walkie Talkie is not running"
            : "🎚️ From Walkie: could not turn off (OSStatus \(err))")
    }

    // MARK: - CoreAudio

    private static var acquired = AudioObjectPropertyAddress(
        mSelector: kAudioBoxPropertyAcquired,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func box() -> AudioObjectID? {
        var uid = boxUID as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToBox,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return (err == noErr && id != kAudioObjectUnknown) ? id : nil
    }

    private static func isOn(_ box: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(box, &acquired, 0, nil, &size, &value)
        return value != 0
    }

    private static func set(_ box: AudioObjectID, on: Bool) -> OSStatus {
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(box, &acquired, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
