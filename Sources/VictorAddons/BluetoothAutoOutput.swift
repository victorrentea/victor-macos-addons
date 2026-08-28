import CoreAudio
import Foundation

/// Makes the JBL speakers the macOS default output the moment they connect
/// over Bluetooth — macOS does that on its own only sometimes, and when it
/// doesn't, a sound fired from the soundboard goes to the laptop speakers in
/// front of a room.
///
/// **Why this costs no battery.** There is no polling. CoreAudio publishes the
/// device list as a property (`kAudioHardwarePropertyDevices`) and lets us
/// register a listener block on it; `coreaudiod` calls that block only when a
/// device actually appears or disappears — which, for a Bluetooth speaker, is
/// exactly the connect/disconnect moment. Between events the app is asleep and
/// schedules no timer wakeups at all, so this is strictly cheaper than the 30 s
/// `BluetoothKeepAlive` heartbeat next to it. The only timers are the two short
/// bounded retries after a connect (see below).
///
/// **Why a retry.** A speaker shows up in the device list a moment before
/// CoreAudio will accept it as the default output (the A2DP stream is still
/// being set up), and macOS may also finish its own route decision just after
/// ours. So the switch is attempted immediately, then verified and re-applied
/// at +1 s and +2.5 s. After that we stop; three attempts on a connect edge are
/// invisible on battery.
///
/// The decision itself is in `BluetoothAutoOutputPolicy` — including why we act
/// on the *appearance edge* only, and therefore never fight a manual choice of
/// output while the speakers stay connected.
final class BluetoothAutoOutput {
    /// Retry offsets after the immediate attempt, in seconds.
    private static let retryDelays: [TimeInterval] = [1.0, 2.5]

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.bt-auto-output", qos: .utility)
    /// Matching output-device names seen in the previous snapshot. Queue only.
    private var lastSeen: Set<String> = []
    private var listener: AudioObjectPropertyListenerBlock?
    private var listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            // Seed without acting: speakers already connected at launch keep
            // whatever output the user has chosen.
            self.lastSeen = Self.matchingOutputNames()
            let seeded = self.lastSeen.sorted().joined(separator: ", ")
            overlayInfo("🔵 BT auto-output armed (device-list listener, no polling)"
                + (seeded.isEmpty ? "" : " — already connected: \(seeded)"))
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceListChanged()
        }
        listener = block
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectAddPropertyListenerBlock(sys, &listenerAddress, queue, block)
        if status != noErr {
            overlayError("BT auto-output: could not observe the device list (OSStatus \(status))")
        }
    }

    func stop() {
        guard let block = listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listenerAddress, queue, block)
        listener = nil
    }

    deinit { stop() }

    // MARK: - Internals

    /// Runs on `queue` (CoreAudio dispatches the listener there).
    private func deviceListChanged() {
        let current = Self.matchingOutputNames()
        let previous = lastSeen
        lastSeen = current
        let defaultName = BluetoothOutput.defaultOutput().name
        guard let target = BluetoothAutoOutputPolicy.evaluate(
            previous: previous, current: current, defaultOutput: defaultName) else { return }
        overlayInfo("🔊 '\(target)' connected → making it the default output (was '\(defaultName)')")
        attempt(target: target, remaining: Self.retryDelays)
    }

    /// Try to make `target` the default output; if it didn't take, retry after
    /// the next delay. Always on `queue`.
    private func attempt(target: String, remaining: [TimeInterval]) {
        if BluetoothOutput.defaultOutput().name == target { return }  // done (by us or by macOS)
        if let device = Self.matchingOutputDevices().first(where: { $0.name == target }) {
            BluetoothOutput.setDefaultOutput(device.id)
            if BluetoothOutput.defaultOutput().name == target {
                overlayInfo("✅ Default output is now '\(target)'")
                return
            }
        }
        guard let next = remaining.first else {
            overlayError("BT auto-output: '\(target)' would not take the default output")
            return
        }
        queue.asyncAfter(deadline: .now() + next) { [weak self] in
            self?.attempt(target: target, remaining: Array(remaining.dropFirst()))
        }
    }

    /// Connected Bluetooth output devices whose name matches the speakers.
    private static func matchingOutputDevices() -> [BluetoothOutput.OutputDevice] {
        BluetoothOutput.outputDevices().filter { $0.isBluetooth && BluetoothAutoOutputPolicy.matches($0.name) }
    }

    private static func matchingOutputNames() -> Set<String> {
        Set(matchingOutputDevices().map(\.name))
    }
}
