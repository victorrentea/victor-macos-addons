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
/// Scope: only the active output, and only the speakers that actually need it
/// — the JBL boxes. Other Bluetooth outputs (e.g. "Vic Bose" headphones) don't
/// standby-mute, so pumping a tone into them is pointless. We check the default
/// output device's transport type *and* its name, and emit through the normal
/// default route (AVAudioPlayer), so nothing fires when the default output is
/// wired/built-in, the "🔊OS Output" loopback, or a non-JBL Bluetooth device.
/// No menu toggle — it self-gates on the name.
final class BluetoothKeepAlive {
    private static let interval: TimeInterval = 30
    /// Substring (case-insensitive) a Bluetooth output's name must contain for
    /// the keep-alive to run.
    private static let nameMatch = BluetoothOutput.speakerNameMatch

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.bt-keepalive", qos: .utility)
    private var pollTimer: DispatchSourceTimer?

    /// Pre-rendered near-silent WAV, replayed each tick. AVAudioPlayer(data:)
    /// routes to the current default output device.
    private let keepAliveWav: Data = BluetoothOutput.makeSilentToneWav(seconds: 0.5)
    /// Held strong while it plays so it isn't deallocated mid-playback. Main
    /// thread only (AVAudioPlayer is not thread-safe).
    private var player: AVAudioPlayer?

    /// Last observed "default output is a JBL speaker" state, for
    /// transition-only logging (avoids ~2880 log lines/day from a silent 30s
    /// heartbeat).
    private var lastWasTarget = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fire one tick immediately, then every 30s. 2s leeway lets the OS
        // coalesce the wakeup — this is a battery-friendly background poll.
        timer.schedule(deadline: .now() + 1, repeating: Self.interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        pollTimer = timer
        timer.resume()
        overlayInfo("🔵 BT keep-alive started (every \(Int(Self.interval))s when default output is a Bluetooth '\(Self.nameMatch)' speaker)")
    }

    private func tick() {
        let (isBT, name) = BluetoothOutput.defaultOutput()
        let isTarget = isBT && name.range(of: Self.nameMatch, options: .caseInsensitive) != nil
        if isTarget != lastWasTarget {
            lastWasTarget = isTarget
            if isTarget {
                overlayInfo("🔵 BT keep-alive active → default output '\(name)' is a Bluetooth '\(Self.nameMatch)' speaker")
            } else {
                overlayInfo("⚪️ BT keep-alive idle → default output '\(name)' is not a Bluetooth '\(Self.nameMatch)' speaker")
            }
        }
        guard isTarget else { return }
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
