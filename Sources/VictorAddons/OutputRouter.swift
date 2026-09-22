import CoreAudio
import Foundation

/// **Keeps the sound on a device that can actually play it.**
///
/// Two jobs, one owner. It replaced `BluetoothAutoOutput` on 2026-09-22, which
/// did the first half only:
///
/// 1. **The ladder** — the Bose headset outranks the JBL speakers, which
///    outrank everything else. Connecting the speakers makes them the output
///    (macOS does that on its own only sometimes, and when it doesn't a sound
///    fired from the soundboard goes to the laptop speakers in front of a
///    room); connecting the headset takes the sound off the boxes without
///    disconnecting them; taking the headset off gives the boxes the sound
///    back.
/// 2. **The blocklist** — the DJI Mic Mini pairs over Bluetooth as an HFP
///    headset, so macOS publishes a one-channel *output* for a lavalier that
///    has no speaker in it, and routes meetings into it. Whenever either
///    default output lands there it is put straight back.
///
/// The decisions are all in `OutputRouterPolicy`, including why an appearance
/// edge never fights a manual choice.
///
/// **Why this costs no battery.** There is no polling. CoreAudio publishes the
/// device list and both default-output selections as properties and lets us
/// register listener blocks on them; `coreaudiod` calls those blocks only when
/// something actually changes — which, for a Bluetooth speaker, is exactly the
/// connect/disconnect moment. Between events the app is asleep and schedules no
/// timer wakeups at all. The only timers are the two short bounded retries after
/// a connect.
///
/// **Why a retry.** A speaker shows up in the device list a moment before
/// CoreAudio will accept it as the default output (the A2DP stream is still
/// being set up), and macOS may also finish its own route decision just after
/// ours. So the switch is attempted immediately, then verified and re-applied at
/// +1 s and +2.5 s. After that we stop; three attempts on a connect edge are
/// invisible on battery.
final class OutputRouter {
    /// Retry offsets after the immediate attempt, in seconds.
    private static let retryDelays: [TimeInterval] = [1.0, 2.5]

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.output-router", qos: .utility)
    /// Every output-device name seen in the previous snapshot. Queue only.
    private var lastSeen: Set<String> = []

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static let deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static let systemOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            // Seed without acting on the ladder: devices already connected at
            // launch keep whatever output Victor has chosen.
            self.lastSeen = Set(BluetoothOutput.outputDevices().map(\.name))
            let ranked = self.lastSeen.filter { OutputRouterPolicy.rank($0) != nil }.sorted()
            overlayInfo("🔵 Output router armed (device list + both default outputs, no polling)"
                + (ranked.isEmpty ? "" : " — on the ladder: \(ranked.joined(separator: ", "))"))
            // The blocklist IS acted on at launch, and deliberately: a DJI that
            // grabbed the system output an hour ago is still holding it, and a
            // restart is the one moment we get to notice.
            self.rescueIfBlocked()
        }

        observe(Self.deviceListAddress) { [weak self] in self?.deviceListChanged() }
        observe(Self.defaultOutputAddress) { [weak self] in self?.rescueIfBlocked() }
        observe(Self.systemOutputAddress) { [weak self] in self?.rescueIfBlocked() }
    }

    func stop() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for (address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(sys, &addr, queue, block)
        }
        listeners = []
    }

    deinit { stop() }

    // MARK: - Internals

    private func observe(_ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var addr = address
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        if status != noErr {
            overlayError("Output router: could not observe \(fourCC(address.mSelector)) (OSStatus \(status))")
            return
        }
        listeners.append((address, block))
    }

    private func fourCC(_ selector: AudioObjectPropertySelector) -> String {
        let raw = UInt32(selector)
        return String(bytes: [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                              UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)], encoding: .ascii) ?? "????"
    }

    /// Runs on `queue` (CoreAudio dispatches the listener there).
    private func deviceListChanged() {
        let devices = BluetoothOutput.outputDevices()
        let current = Set(devices.map(\.name))
        let previous = lastSeen
        lastSeen = current

        // A device list that changed may also have changed where macOS points
        // the defaults — a DJI connecting is both edges at once.
        rescueIfBlocked()

        let defaultName = BluetoothOutput.defaultOutput().name
        guard let target = OutputRouterPolicy.takeoverTarget(
            previous: previous, current: current, defaultOutput: defaultName) else { return }
        overlayInfo("🔊 '\(target)' takes the output (was '\(defaultName)')")
        attempt(target: target, system: false, remaining: Self.retryDelays)
    }

    /// Put either default back on something that can play, if it has landed on a
    /// device that cannot. Runs on `queue`.
    private func rescueIfBlocked() {
        let devices = BluetoothOutput.outputDevices()
        let names = devices.map(\.name)
        let fallback = BluetoothOutput.builtInOutputName()

        // The media output first, so the system output can then be pointed at
        // the device the media output ended up on rather than at the ladder's
        // own idea — the two are normally the same device and should stay so.
        for system in [false, true] {
            let currentID = system ? BluetoothOutput.defaultSystemOutputID() : BluetoothOutput.defaultOutputID()
            guard currentID != 0 else { continue }
            let currentName = BluetoothOutput.deviceName(currentID)
            let mediaID = BluetoothOutput.defaultOutputID()
            let prefer = (system && mediaID != 0) ? BluetoothOutput.deviceName(mediaID) : nil
            guard let target = OutputRouterPolicy.rescueTarget(
                devices: names, defaultOutput: currentName,
                prefer: prefer, fallback: fallback) else { continue }
            let which = system ? "system output (alerts)" : "output"
            overlayInfo("🚫 '\(currentName)' is a microphone, not a speaker — \(which) → '\(target)'")
            attempt(target: target, system: system, remaining: Self.retryDelays)
        }
    }

    /// Try to make `target` the chosen default; if it didn't take, retry after
    /// the next delay. Always on `queue`.
    private func attempt(target: String, system: Bool, remaining: [TimeInterval]) {
        let readBack: () -> String = {
            let id = system ? BluetoothOutput.defaultSystemOutputID() : BluetoothOutput.defaultOutputID()
            return id == 0 ? "?" : BluetoothOutput.deviceName(id)
        }
        if readBack() == target { return }  // done (by us or by macOS)
        if let device = BluetoothOutput.outputDevices().first(where: { $0.name == target }) {
            if system {
                BluetoothOutput.setDefaultSystemOutput(device.id)
            } else {
                BluetoothOutput.setDefaultOutput(device.id)
            }
            if readBack() == target {
                overlayInfo("✅ \(system ? "System output" : "Default output") is now '\(target)'")
                return
            }
        }
        guard let next = remaining.first else {
            overlayError("Output router: '\(target)' would not take the \(system ? "system " : "")output")
            return
        }
        queue.asyncAfter(deadline: .now() + next) { [weak self] in
            self?.attempt(target: target, system: system, remaining: Array(remaining.dropFirst()))
        }
    }
}
