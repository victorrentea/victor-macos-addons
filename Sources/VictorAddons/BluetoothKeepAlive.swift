import AVFoundation
import CoreAudio
import Foundation

/// Keeps a Bluetooth speaker from dropping into power-save/standby between
/// sounds. Many BT speakers mute their amplifier after a few seconds of
/// silence, which clips the start of the next sound (a problem now that the
/// Mac renders the tablet-routed soundboard). Every 30s, if the *current
/// default output device* is a Bluetooth speaker, we play a ~0.5s near-silent
/// tone (≈ -56 dBFS, inaudible in a room) to keep the stream — and the amp —
/// alive.
///
/// Scope: only the active output. We check the default output device's
/// transport type and emit through the normal default route (AVAudioPlayer),
/// so nothing fires when the default output is wired/built-in or the
/// "🔊OS Output" loopback. No menu toggle — it self-gates on BT presence.
final class BluetoothKeepAlive {
    private static let interval: TimeInterval = 30

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.bt-keepalive", qos: .utility)
    private var pollTimer: DispatchSourceTimer?

    /// Pre-rendered near-silent WAV, replayed each tick. AVAudioPlayer(data:)
    /// routes to the current default output device.
    private let keepAliveWav: Data = BluetoothKeepAlive.makeKeepAliveWav()
    /// Held strong while it plays so it isn't deallocated mid-playback. Main
    /// thread only (AVAudioPlayer is not thread-safe).
    private var player: AVAudioPlayer?

    /// Last observed "default output is Bluetooth" state, for transition-only
    /// logging (avoids ~2880 log lines/day from a silent 30s heartbeat).
    private var lastWasBluetooth = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fire one tick immediately, then every 30s. 2s leeway lets the OS
        // coalesce the wakeup — this is a battery-friendly background poll.
        timer.schedule(deadline: .now() + 1, repeating: Self.interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        pollTimer = timer
        timer.resume()
        overlayInfo("🔵 BT keep-alive started (every \(Int(Self.interval))s when default output is Bluetooth)")
    }

    private func tick() {
        let (isBT, name) = defaultOutputBluetooth()
        if isBT != lastWasBluetooth {
            lastWasBluetooth = isBT
            if isBT {
                overlayInfo("🔵 BT keep-alive active → default output '\(name)' is Bluetooth")
            } else {
                overlayInfo("⚪️ BT keep-alive idle → default output '\(name)' is not Bluetooth")
            }
        }
        guard isBT else { return }
        DispatchQueue.main.async { [weak self] in self?.playKeepAlive() }
    }

    private func playKeepAlive() {
        do {
            let p = try AVAudioPlayer(data: keepAliveWav)
            p.volume = 1.0  // amplitude is baked into the samples
            p.prepareToPlay()
            player = p
            p.play()
        } catch {
            overlayError("BT keep-alive play failed: \(error)")
        }
    }

    /// (isBluetooth, deviceName) for the current default output device.
    private func defaultOutputBluetooth() -> (Bool, String) {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &devAddr, 0, nil, &size, &devID) == noErr, devID != 0 else {
            return (false, "?")
        }

        var transAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(devID, &transAddr, 0, nil, &tsize, &transport) == noErr else {
            return (false, deviceName(devID))
        }
        let isBT = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
        return (isBT, deviceName(devID))
    }

    private func deviceName(_ devID: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &nameSize) == noErr else { return "?" }
        var n: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &nameSize, &n) == noErr else { return "?" }
        return (n?.takeRetainedValue() as String?) ?? "?"
    }

    // MARK: - Tone generation

    /// Build a mono 16-bit PCM WAV of a short, very quiet sine burst with
    /// 10ms fades (no click). Generated once at startup; AVAudioPlayer(data:)
    /// replays it each tick.
    private static func makeKeepAliveWav() -> Data {
        let sampleRate = 44100
        let duration = 0.5
        let frames = Int(Double(sampleRate) * duration)
        let amplitude = 0.0015  // ≈ -56 dBFS: inaudible, but real PCM energy
        let freq = 220.0
        let fade = Int(0.01 * Double(sampleRate))  // 10ms fade in/out

        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            var a = amplitude
            if i < fade {
                a *= Double(i) / Double(fade)
            } else if i >= frames - fade {
                a *= Double(frames - i) / Double(fade)
            }
            let v = sin(2.0 * Double.pi * freq * Double(i) / Double(sampleRate)) * a
            samples[i] = Int16((max(-1.0, min(1.0, v)) * 32767.0).rounded())
        }

        let bytesPerSample = 2
        let dataSize = frames * bytesPerSample
        let byteRate = sampleRate * bytesPerSample

        var d = Data()
        func appendLE32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)                       // PCM fmt chunk size
        appendLE16(1)                        // audio format = PCM
        appendLE16(1)                        // channels = mono
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(byteRate))
        appendLE16(UInt16(bytesPerSample))   // block align
        appendLE16(16)                       // bits per sample
        d.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(dataSize))
        for s in samples {
            var x = s.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        return d
    }
}
