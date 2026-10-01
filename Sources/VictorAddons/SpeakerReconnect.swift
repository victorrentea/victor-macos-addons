import Foundation
import IOBluetooth

/// **Keeps every JBL box that is switched on connected to the Mac**, so the
/// second one is a real spare and not a speaker quietly timing itself out in
/// standby. The reasoning and the cadences are in `SpeakerReconnectPolicy`.
///
/// A 30 s check reads the paired-device list (no radio — just IOBluetooth's
/// cached state) and pages the boxes the policy says to. A page is
/// `openConnection()`, the same call `blueutil --connect` makes: on a box that
/// is on it brings up the link and macOS adds the A2DP output on its own; on a
/// box that is off it fails after ~15 s and costs nothing else.
///
/// IOBluetooth work runs on its own `RunLoopThread` (see there for why), and
/// the synchronous page blocks only that thread.
final class SpeakerReconnect {
    private static let checkEvery: TimeInterval = 30

    private let bt = RunLoopThread(name: "ro.victorrentea.macos-addons.speaker-reconnect")
    private var timer: DispatchSourceTimer?

    // Touched only on `bt`.
    private var lastSeenConnected: Date?
    private var lastAttempt: [String: Date] = [:]
    private var lastConnected: Set<String> = []

    func start() {
        bt.start()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: Self.checkEvery, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.bt.async { self?.check() } }
        timer = t
        t.resume()
        overlayInfo("🔊 Speaker reconnect armed (connects every JBL box that is on, checked every \(Int(Self.checkEvery))s)")
    }

    private func check() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let speakers = paired.filter {
            SpeakerReconnectPolicy.isSpeaker(name: $0.name ?? "", major: $0.deviceClassMajor,
                                             minor: $0.deviceClassMinor)
        }
        let connected = speakers.filter { $0.isConnected() }
        let now = Date()
        if !connected.isEmpty { lastSeenConnected = now }

        let names = Set(connected.compactMap(\.name))
        if names != lastConnected {
            let lost = lastConnected.subtracting(names)
            if !lost.isEmpty {
                // Page the spare right away instead of at its next 3-min slot.
                lastAttempt = [:]
                overlayInfo("🔇 JBL box gone: \(lost.sorted().joined(separator: ", "))"
                    + (names.isEmpty
                        ? " — none left, looking for one every \(Int(SpeakerReconnectPolicy.whileUncovered))s for \(Int(SpeakerReconnectPolicy.graceAfterLoss / 60)) min"
                        : " — still on \(names.sorted().joined(separator: ", "))"))
            }
            lastConnected = names
        }

        for speaker in speakers where !speaker.isConnected() {
            let address = speaker.addressString ?? ""
            guard SpeakerReconnectPolicy.shouldPage(
                anyConnected: !connected.isEmpty, lastSeenConnected: lastSeenConnected,
                lastAttempt: lastAttempt[address], now: now) else { continue }
            lastAttempt[address] = now
            // Failure is the common case (the box is off) and stays out of the
            // log: at 30 s that would be a line per box per half-minute.
            if speaker.openConnection() == kIOReturnSuccess {
                overlayInfo("🔊 '\(speaker.name ?? address)' was on but not connected — connected it")
            }
        }
    }
}
