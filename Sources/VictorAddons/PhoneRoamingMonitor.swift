import AppKit
import Foundation
import IOBluetooth

/// Asks the phone, over Bluetooth, how much of the roaming allowance is left.
///
/// The phone (`victor-phone-addons`) already counts roaming traffic for its
/// ROAMING DATA card; it publishes a second RFCOMM service beside the hotspot
/// beacon, `RoamingStatusChannel`, which answers every connection with one
/// line of JSON and waits for us to hang up.
///
/// **Why a service of its own.** On the beacon's SPP channel the *connection*
/// is the signal: accepting it brings the phone's activity to the front, and
/// the Samsung routine turns the hotspot on at "App opened". Asking about
/// roaming on that channel would switch the hotspot on every 20 minutes.
///
/// **Why Bluetooth and not HTTP.** The phone is only reachable over IP while
/// the Mac is on its hotspot — and a roaming day on hotel Wi-Fi still eats the
/// same allowance. Bluetooth reaches it wherever it is in range, which is
/// wherever Victor is. The cost is a page every poll (the link drops a few
/// seconds after each short connection), ~4 s cold; that is why the poll is
/// every 20 minutes and not more often — the numbers do not move faster than
/// that in any way that matters against a 13.7 GB ceiling.
///
/// The channel opening is `PhoneChannelOpener`, shared with `HotspotFallback`,
/// so it inherits the stale-channel-number and cold-link fixes that one paid for.
final class PhoneRoamingMonitor {

    /// Must equal `RoamingStatusChannel.UUID_ROAMING` on the phone.
    static let serviceUUID: [UInt8] = [
        0x7a, 0x1f, 0x3c, 0x52, 0x9b, 0x4e, 0x4d, 0x1a,
        0x8c, 0x6f, 0x2e, 0x5b, 0x9d, 0x0a, 0x4f, 0x17,
    ]
    static let pollInterval: TimeInterval = 20 * 60
    /// Page + SDP + open + the phone's reading. The opener gives up on its own
    /// well inside this; the budget only guards against a callback that never comes.
    private static let pollBudget: TimeInterval = 45

    private let queue = DispatchQueue(label: "ro.victorrentea.phone-roaming", qos: .utility)
    private let bluetooth = RunLoopThread(name: "ro.victorrentea.macos-addons.bluetooth-roaming")
    private var timer: DispatchSourceTimer?

    // Touched on `bluetooth` only.
    private var opener: PhoneChannelOpener?
    private var channel: IOBluetoothRFCOMMChannel?
    private var buffer = Data()

    private let lock = NSLock()
    private var _reading: RoamingWarningPolicy.Reading?
    private var _simulated: RoamingWarningPolicy.Reading?
    private var _lastPollAt: Date?
    private var _lastError: String?
    private var _lastLine: String?
    private var pollInFlight = false

    /// Fired on the main thread after every poll, with the current reading
    /// (nil when there has never been one).
    var onReading: ((RoamingWarningPolicy.Reading?) -> Void)?

    var reading: RoamingWarningPolicy.Reading? {
        lock.lock(); defer { lock.unlock() }
        return _simulated ?? _reading
    }

    func start() {
        guard timer == nil else { return }
        bluetooth.start()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.poll(reason: "timer") }
        t.resume()
        timer = t
        // Sleeping drops the link and may have crossed midnight or a border.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 30) { self?.poll(reason: "wake") }
        }
    }

    /// `GET /test/roaming` — poll now (async), answer with the previous state.
    func pollNow() { queue.async { [weak self] in self?.poll(reason: "test") } }

    /// `GET /test/roaming/simulate/<pct>` — pretend the phone roams today with
    /// `pct`% left; `pct` < 0 clears the simulation. Shadows the real reading.
    func simulate(remainingPct: Int) {
        lock.lock()
        if remainingPct < 0 {
            _simulated = nil
        } else {
            let limit: Int64 = 13_703_000_000
            _simulated = RoamingWarningPolicy.Reading(
                cycleTotal: limit - limit * Int64(remainingPct) / 100, cycleHotspot: 0, today: 1,
                roamingNow: true, limit: limit, lowFraction: 0.15,
                nextReset: Date().addingTimeInterval(86_400), readAt: Date())
        }
        let r = _simulated ?? _reading
        lock.unlock()
        overlayInfo("📶 roaming: simulating \(remainingPct)% left")
        DispatchQueue.main.async { self.onReading?(r) }
    }

    var diagnosticsJSON: String {
        lock.lock(); defer { lock.unlock() }
        let r = _simulated ?? _reading
        var o: [String: Any] = [
            "simulated": _simulated != nil,
            "last_poll_at": _lastPollAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "last_error": _lastError ?? NSNull(),
            "last_line": _lastLine ?? NSNull(),
        ]
        if let r {
            o["cycle_total"] = r.cycleTotal
            o["today"] = r.today
            o["roaming_now"] = r.roamingNow
            o["limit"] = r.limit
            o["remaining_pct"] = Int(r.remainingFraction * 100)
            o["low"] = r.low
            o["read_at"] = ISO8601DateFormatter().string(from: r.readAt)
        }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Polling (on `queue`)

    private func poll(reason: String) {
        guard !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }

        var line: String?
        var error: String? = "the phone never answered"
        let done = DispatchSemaphore(value: 0)
        var signalled = false
        let finish: (String?, String?) -> Void = { l, why in
            guard !signalled else { return }
            signalled = true
            line = l
            error = why
            done.signal()
        }

        bluetooth.async { [weak self] in
            guard let self else { return finish(nil, "shutting down") }
            guard let dev = IOBluetoothDevice(addressString: HotspotFallback.phoneBluetoothAddress) else {
                return finish(nil, "phone not in the Bluetooth pairing list")
            }
            self.buffer = Data()
            let uuid = Self.serviceUUID.withUnsafeBytes {
                IOBluetoothSDPUUID(bytes: $0.baseAddress, length: $0.count)
            }
            let opener = PhoneChannelOpener(device: dev, service: uuid, serviceName: "roaming status") { [weak self] outcome in
                switch outcome {
                case .opened(let ch, _):
                    self?.channel = ch
                case .failed(let why):
                    finish(nil, why)
                }
            }
            opener.onData = { [weak self] data in
                guard let self else { return }
                self.buffer.append(data)
                if let nl = self.buffer.firstIndex(of: 0x0A) {
                    finish(String(data: self.buffer[..<nl], encoding: .utf8), nil)
                }
            }
            opener.onClosed = { finish(nil, "the phone closed the channel without an answer") }
            self.opener = opener
            opener.start()
        }

        _ = done.wait(timeout: .now() + Self.pollBudget)
        // Hang up on the Bluetooth thread, where the channel lives; the phone
        // is waiting for exactly this to free its socket for the next caller.
        bluetooth.async { [weak self] in
            self?.opener?.onClosed = nil
            self?.channel?.close()
            self?.channel = nil
            self?.opener = nil
        }

        let parsed = line.flatMap(RoamingWarningPolicy.parse)
        if line != nil, parsed == nil { error = "unreadable answer from the phone" }
        lock.lock()
        _lastPollAt = Date()
        _lastLine = line
        _lastError = error
        if let parsed { _reading = parsed }
        let current = _simulated ?? _reading
        lock.unlock()

        if let parsed {
            overlayInfo("📶 roaming (\(reason)): \(RoamingWarningPolicy.gb(parsed.cycleTotal)) of " +
                        "\(RoamingWarningPolicy.gb(parsed.limit)), today \(RoamingWarningPolicy.gb(parsed.today))" +
                        "\(parsed.roamingNow ? ", roaming now" : "")\(parsed.low ? " — LOW" : "")")
        } else {
            overlayInfo("📵 roaming poll (\(reason)) failed: \(error ?? "?")")
        }
        DispatchQueue.main.async { self.onReading?(current) }
    }
}
