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
    private let keepAliveWav: Data = BluetoothOutput.makeSilentToneWav(seconds: 0.5)
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
        let (isBT, name) = BluetoothOutput.defaultOutput()
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

}
