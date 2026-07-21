import Foundation
import IOBluetooth

/// Low-battery warnings for Victor's JBL Go 4 Bluetooth speakers.
///
/// ## How the battery is read (no proprietary protocol needed)
/// The JBL Go 4 exposes the **Google Fast Pair "Message Stream"** over an
/// RFCOMM channel (SDP service UUID `df21fe2c-2515-4fdb-8886-f12c4d67927c`,
/// advertised as `GFPS3`). This is a *public* Google protocol, not JBL's own —
/// so we don't have to reverse-engineer anything. Message framing is:
///
///     [group:u8][code:u8][len:u16 big-endian][payload…]
///
/// The speaker pushes a **Battery updated** message (`group=0x03 code=0x03`)
/// whose payload is 1–3 battery bytes, each encoded as:
///   * bit 7  → charging
///   * bits 0-6 → level percent (0–100), or `0x7F` = unknown
///
/// ## Why we hold the channel open (instead of polling)
/// Empirically the Go 4 firmware **only emits battery when the value changes** —
/// it does *not* answer a poll and does *not* dump battery on connect (it sends
/// only Model ID + BLE address on connect, verified live). There is no request
/// message for battery in the Fast Pair spec either. So the only way to observe
/// battery is to keep the message-stream channel open and react to change
/// pushes. That's a perfect fit for the actual goal: during a workshop the
/// speaker plays audio and discharges, emitting a push at every percent — which
/// is exactly when we want to warn (15/10/5% ≈ the moment the red LED lights up).
/// The trade-off: right after connecting we don't know the current level until
/// the first change — acceptable, since the thresholds we care about happen
/// during active discharge.
///
/// The monitor is UI-agnostic: it just decodes battery and invokes callbacks;
/// `AppDelegate` decides how to surface it (persistent notification + banner).
final class SpeakerBatteryMonitor: NSObject, IOBluetoothRFCOMMChannelDelegate {

    /// Fast Pair Message Stream RFCOMM service UUID (128-bit).
    private static let fastPairMessageStreamUUID = IOBluetoothSDPUUID(
        bytes: [0xdf, 0x21, 0xfe, 0x2c, 0x25, 0x15, 0x4f, 0xdb,
                0x88, 0x86, 0xf1, 0x2c, 0x4d, 0x67, 0x92, 0x7c] as [UInt8],
        length: 16)

    /// Warn at these levels, most-urgent last. Each fires once per discharge
    /// episode; re-armed when the speaker charges back above the threshold.
    static let thresholds = [15, 10, 5]

    /// Only speakers whose name contains this are monitored (keeps us off mice
    /// etc.); matches "Victor's JBL Go 4" and the bare "JBL".
    private static let nameNeedle = "JBL"

    private final class SpeakerState {
        let address: String
        var name: String
        var level: Int?
        var charging = false
        /// Thresholds already notified during the current discharge episode.
        var fired: Set<Int> = []
        var channel: IOBluetoothRFCOMMChannel?
        var opening = false
        init(address: String, name: String) { self.address = address; self.name = name }
    }

    /// key = device address string ("e8-26-cf-c6-f3-69")
    private var states: [String: SpeakerState] = [:]
    private var timer: DispatchSourceTimer?

    // MARK: Callbacks (wired by AppDelegate)

    /// Battery dropped to `threshold`% (one of `thresholds`) while discharging.
    /// `level` is the actual reported value (≤ threshold). Fire the warning.
    var onLowBattery: ((_ name: String, _ level: Int, _ threshold: Int) -> Void)?
    /// Speaker started charging / climbed back above every threshold → recovery.
    /// Clear any persistent low-battery warning for this speaker.
    var onCleared: ((_ name: String) -> Void)?
    /// Any battery update (for logging / an optional live banner).
    var onUpdate: ((_ name: String, _ level: Int, _ charging: Bool) -> Void)?

    // MARK: Lifecycle

    /// Poll every 15s: (re)discover connected JBL speakers and (re)open their
    /// message-stream channel. IOBluetooth delivers RFCOMM callbacks on the
    /// main run loop, so we drive everything from the main queue.
    func start() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 15)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        overlayInfo("🔋 SpeakerBatteryMonitor started")
    }

    private func tick() {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for dev in paired {
            guard let name = dev.name, name.localizedCaseInsensitiveContains(Self.nameNeedle) else { continue }
            guard let addr = dev.addressString else { continue }
            guard dev.isConnected() else {
                // Disconnected: drop any open channel; keep the last known state.
                if let st = states[addr] { st.channel = nil; st.opening = false }
                continue
            }
            let st = states[addr] ?? {
                let s = SpeakerState(address: addr, name: name); states[addr] = s; return s
            }()
            st.name = name
            if st.channel == nil && !st.opening { openChannel(for: dev, state: st) }
        }
    }

    private func openChannel(for dev: IOBluetoothDevice, state st: SpeakerState) {
        // Resolve the Fast Pair RFCOMM channel from SDP (cached after pairing).
        guard let rec = dev.getServiceRecord(for: Self.fastPairMessageStreamUUID) else {
            dev.performSDPQuery(nil)   // not cached yet — retry next tick
            return
        }
        var ch: BluetoothRFCOMMChannelID = 0
        guard rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess, ch != 0 else { return }
        st.opening = true
        var channel: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&channel, withChannelID: ch, delegate: self)
        if r == kIOReturnSuccess {
            st.channel = channel
        } else {
            st.opening = false
        }
    }

    // MARK: RFCOMM delegate

    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard let addr = ch.getDevice()?.addressString, let st = states[addr] else { return }
        st.opening = false
        if error != kIOReturnSuccess {
            st.channel = nil
            return
        }
        overlayInfo("🔋 Fast Pair message stream open: \(st.name)")
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int) {
        guard let addr = ch.getDevice()?.addressString, let st = states[addr] else { return }
        let data = Data(bytes: ptr, count: len)
        parseMessages(data, into: st)
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        guard let addr = ch.getDevice()?.addressString, let st = states[addr] else { return }
        st.channel = nil
        st.opening = false
    }

    // MARK: Fast Pair parsing

    private func parseMessages(_ d: Data, into st: SpeakerState) {
        var i = d.startIndex
        while i + 4 <= d.endIndex {
            let group = d[i]
            let code = d[i + 1]
            let plen = (Int(d[i + 2]) << 8) | Int(d[i + 3])
            let payloadStart = i + 4
            guard payloadStart + plen <= d.endIndex else { break }
            if group == 0x03, code == 0x03 {   // Battery updated
                // For a single-battery speaker there's one byte; if a device
                // ever reports several, take the lowest known level.
                var lowest: Int?
                var anyCharging = false
                for j in 0..<plen {
                    let b = d[payloadStart + j]
                    if (b & 0x80) != 0 { anyCharging = true }
                    let lvl = Int(b & 0x7f)
                    if lvl != 0x7f { lowest = min(lowest ?? lvl, lvl) }
                }
                if let lvl = lowest { handleBattery(level: lvl, charging: anyCharging, st: st) }
            }
            i = payloadStart + plen
        }
    }

    /// Threshold state machine. Fires `onLowBattery` once per threshold while
    /// discharging; re-arms a threshold once the speaker climbs back above it,
    /// and clears everything (with `onCleared`) as soon as it's charging.
    private func handleBattery(level: Int, charging: Bool, st: SpeakerState) {
        st.level = level
        st.charging = charging
        onUpdate?(st.name, level, charging)
        overlayInfo("🔋 \(st.name): \(level)%\(charging ? " ⚡charging" : "")")

        if charging {
            if !st.fired.isEmpty { onCleared?(st.name) }
            st.fired.removeAll()
            return
        }
        // Re-arm thresholds we've climbed back above (keep only still-crossed).
        st.fired = st.fired.filter { level <= $0 }
        // Newly crossed thresholds this update.
        let crossed = Self.thresholds.filter { level <= $0 && !st.fired.contains($0) }
        guard let mostUrgent = crossed.min() else { return }
        crossed.forEach { st.fired.insert($0) }
        onLowBattery?(st.name, level, mostUrgent)
    }

    // MARK: Test / diagnostics

    /// JSON snapshot of every known speaker's battery state. Backs
    /// `GET /test/speaker-battery`.
    func snapshotJSON() -> String {
        let items = states.values.map { st -> String in
            let lvl = st.level.map(String.init) ?? "null"
            let fired = st.fired.sorted().map(String.init).joined(separator: ",")
            return "{"
                + "\"name\":\"\(st.name)\","
                + "\"address\":\"\(st.address)\","
                + "\"level\":\(lvl),"
                + "\"charging\":\(st.charging),"
                + "\"channelOpen\":\(st.channel != nil),"
                + "\"firedThresholds\":[\(fired)]"
                + "}"
        }
        return "{\"thresholds\":[\(Self.thresholds.map(String.init).joined(separator: ","))],"
            + "\"speakers\":[\(items.joined(separator: ","))]}"
    }

    /// Inject a synthetic battery reading to exercise the threshold + warning
    /// path without draining a real speaker. Backs
    /// `GET /test/speaker-battery/simulate/<level>?charging=0/1`.
    func simulate(level: Int, charging: Bool) {
        let key = "test-speaker"
        let st = states[key] ?? {
            let s = SpeakerState(address: key, name: "JBL Go 4 (test)"); states[key] = s; return s
        }()
        handleBattery(level: max(0, min(100, level)), charging: charging, st: st)
    }
}
