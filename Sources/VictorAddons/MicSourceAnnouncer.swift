import Cocoa
import CoreAudio

/// **"🎙️ Listening to: <device>"** — a bottom-center tab announcing that the
/// system's default *input* moved: the DJI receiver plugged into USB-C, pulled
/// out again, or the input switched to another device in Sound settings.
///
/// Victor's ask (2026-09-23): when the microphone source changes, say so on
/// screen, briefly. It borrows `BottomTabBanner` — the app's transient
/// announcement surface (`BellCard`, `FxCard`) — rather than inventing a look:
/// rises from the bottom edge, holds ~2.5 s, falls away, click-through,
/// non-activating, never takes focus.
///
/// **What it announces is the system default input**, the device macOS itself
/// points new recordings at. It is *not* necessarily what this app's Whisper
/// engine or Walkie Talkie record through — both resolve their own device from
/// `~/.walkie-talkie/mic/choice` and the `MicRoster` ladder, and fall back to
/// the system default only when none of the known microphones is present.
/// Wispr Flow does follow it, when its microphone is set to *Auto-detect*.
///
/// **Only on a real change, never at launch.** The device present when
/// `start()` runs is the baseline and says nothing. A plug-in fires a burst —
/// `DefaultInputDevice` and `Devices` both, sometimes twice — so every
/// notification just restarts a short settle timer, and only when it expires
/// is the default read once and compared with the last one announced. A
/// burst that ends where it began (A → B → A) announces nothing.
final class MicSourceAnnouncer {

    /// How long the notifications must stay quiet before the default is read.
    static let settle: TimeInterval = 0.6
    /// Shorter than `BottomTabBanner`'s three seconds: a status line, not a name
    /// the room has to read.
    static let hold: TimeInterval = 2.5
    /// Green: "it is listening". Distinct from the bell's amber and the FX red.
    static let tint = NSColor.systemGreen.withAlphaComponent(0.85)

    private let banner = BottomTabBanner(screensProvider: { MicSourceAnnouncer.screenUnderMouse() })
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.mic-source", qos: .utility)
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pending: DispatchWorkItem?
    /// Last device announced (or the baseline). Touched only on `queue`.
    private var lastId: AudioDeviceID = 0

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastId = Self.defaultInputId()
            overlayInfo("🎙️ Mic source: baseline \(Self.name(of: self.lastId) ?? "none")")
            for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
                var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.poke() }
                let status = AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &addr, self.queue, block)
                if status == noErr {
                    self.listeners.append((addr, block))
                } else {
                    overlayError("🎙️ Mic source: could not observe selector \(selector) (OSStatus \(status))")
                }
            }
        }
    }

    /// Restart the settle timer. Runs on `queue`.
    private func poke() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func settled() {
        let id = Self.defaultInputId()
        guard id != 0, id != lastId else { return }
        lastId = id
        let name = Self.name(of: id) ?? "input \(id)"
        overlayInfo("🎙️ Mic source → \(name)")
        let text = Self.cardText(deviceName: name)
        DispatchQueue.main.async { [banner] in
            banner.show(text: text, backgroundColor: Self.tint, hold: Self.hold)
        }
    }

    /// The exact tab copy. Pure, so the wording is testable.
    static func cardText(deviceName: String) -> String {
        "🎙️ Listening to: \(deviceName.nonBlank(or: "unknown input"))"
    }

    /// The screen the mouse is on — where Victor is looking — or the main one.
    static func screenUnderMouse() -> [NSScreen] {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) { return [s] }
        return NSScreen.main.map { [$0] } ?? []
    }

    // MARK: - CoreAudio

    static func defaultInputId() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    static func name(of id: AudioDeviceID) -> String? {
        guard id != 0 else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
