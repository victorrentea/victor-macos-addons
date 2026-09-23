import Cocoa
import CoreAudio

/// **"🎤 Listening to: DJI"** on the standard bottom-left status
/// pill (`StatusBanner`) when the microphone **this app's Whisper records
/// through** changes — plus the listener that runs `HeadphoneMicGuard`.
///
/// **History, 2026-09-23.** The first version (same day) announced the *system
/// default input* on the green bottom-centre `BottomTabBanner` tab, and on the
/// first real plug-in it said nothing: the DJI receiver went into USB-C, Walkie
/// Talkie and Whisper both moved to it, and the system default stayed on the
/// WH-1000XM3. Victor then split it: *"pune notificarea verde de jos sa vina de
/// la walkie"* — the green tab is Walkie Talkie's now — *"iar macos addons sa
/// afiseze independent notificarea lui standard overlay stg jos"*.
///
/// **What it announces is Whisper's own answer**: the `VICTOR_SOURCE:` glyph
/// `whisper_runner.py` emits whenever `_resolve_device_coreaudio` switches the
/// Victor channel, which it re-asks on a CoreAudio device-list change and on a
/// change of the preference derived from `~/.walkie-talkie/mic/choice`. Reusing
/// that event instead of resolving again in Swift is the point — a second
/// resolver is a second way for the pill and the recording to disagree. The
/// glyph is mapped onto `MicRoster` for the label; nothing here reads Walkie
/// Talkie. Debounced 0.6 s; the first source after launch is the baseline and
/// is never announced; a burst that ends where it began says nothing.
///
/// **The system-default listeners stay, and announce nothing.** They exist so
/// `HeadphoneMicGuard` can move the default input off the WH-1000XM3; that move
/// changes nothing Whisper records through, so it raises no pill — which is
/// what keeps the guard from producing a second, contradictory notification.
final class MicSourceAnnouncer {

    /// How long a burst must stay quiet before it is acted on.
    static let settle: TimeInterval = 0.6
    /// How long the pill stays up: a status line, not a name the room reads.
    static let hold: TimeInterval = 2.5

    private let show: (String) -> Void
    /// Whisper's source glyph last announced, or the baseline. Main thread.
    private var lastSource: String?
    private var candidateSource: String?
    private var pendingSource: DispatchWorkItem?

    /// - Parameter show: puts the text on screen (the bottom-left status pill).
    init(show: @escaping (String) -> Void) {
        self.show = show
    }

    /// Whisper reported the glyph it is capturing through. Main thread.
    func sourceChanged(_ glyph: String) {
        guard lastSource != nil else {
            lastSource = glyph
            overlayInfo("🎙️ Mic source: Whisper baseline \(glyph)")
            return
        }
        candidateSource = glyph
        pendingSource?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sourceSettled() }
        pendingSource = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func sourceSettled() {
        guard let glyph = candidateSource, glyph != lastSource else { return }
        lastSource = glyph
        let text = Self.cardText(glyph: glyph)
        overlayInfo("🎙️ Mic source → \(text)")
        show(text)
    }

    /// The exact copy. Pure, so the wording is testable. A glyph `MicRoster`
    /// does not know is Python's fallback — the raw device name.
    static func cardText(glyph: String) -> String {
        if let mic = MicRoster.byGlyph(glyph) { return "\(mic.glyph) Listening to: \(mic.label)" }
        return "🎙️ Listening to: \(glyph.nonBlank(or: "unknown input"))"
    }

    // MARK: - The system default input, for HeadphoneMicGuard only

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
            // A headset already sitting on the default input at launch is moved
            // now. The move is not announced: it is not what Whisper records.
            HeadphoneMicGuard.enforce()
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
        // Moved off a banned headset → the move re-fires the listener.
        if HeadphoneMicGuard.enforce() { return }
        let id = Self.defaultInputId()
        guard id != 0, id != lastId else { return }
        lastId = id
        overlayInfo("🎙️ System default input → \(Self.name(of: id) ?? "input \(id)") (not announced)")
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
