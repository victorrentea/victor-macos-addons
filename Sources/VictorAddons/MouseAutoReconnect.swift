import Foundation
import IOBluetooth

/// Reconnects Victor's own Bluetooth mouse the moment it is back in range,
/// for the case macOS leaves it sitting paired-but-not-connected (observed:
/// System Settings › Bluetooth shows it "Not Connected" with the mouse awake
/// and on the desk — macOS's own auto-reconnect just doesn't always fire).
///
/// ## Why an allow-list of addresses, not a name match
///
/// This Mac has been paired, over time, with **several different physical
/// mice that all report the exact same name and vendor/product ID** — "Logi
/// M650 L", 0x046D/0xB02A — because it is the same model bought more than
/// once, and possibly paired during a demo with a trainee's identical mouse.
/// `blueutil --paired` on 15 Sep 2026 showed six distinct addresses under
/// that one name, only one of them connected. Matching on the name would
/// happily reconnect any of the other five — someone else's mouse, or a dead
/// one from a drawer — which is exactly what "nu te legi de mouse-urile
/// altora" rules out. So this only ever acts on addresses explicitly listed
/// below, the same allow-list shape `HotspotFallback` uses for the phone.
///
/// ## Why the address survives a factory reset
///
/// Resetting the mouse (to pair it to another computer, then back to this
/// Mac) only clears the *bond* — the BLE address is burned into the chip at
/// the factory and does not change. So an address added here stays correct
/// for that physical mouse forever; it is only unpaired-and-repaired mice
/// that would need a new entry, and `logUnknownMice()` below prints the
/// address of any such stranger so there is never a guess about what to add.
final class MouseAutoReconnect {
    /// Mice confirmed to be Victor's own. `d8-2e-4e-7e-57-ff` is the one seen
    /// connected on 15 Sep 2026 while this feature was written — add a
    /// sibling here (lowercase, hyphenated, as IOBluetooth prints it) for
    /// every other mouse that is genuinely his; see `logUnknownMice()` for
    /// where an unfamiliar one's address shows up.
    private static let trustedAddresses: Set<String> = [
        "d8-2e-4e-7e-57-ff",
    ]

    /// How often a disconnected trusted mouse is retried. Each attempt costs
    /// at most one bounded page (see `pageTimeout`) on a background thread,
    /// so this can afford to be frequent without costing battery the way a
    /// continuous scan would.
    private static let pollInterval: TimeInterval = 20
    /// Bounded so an out-of-range mouse costs a fraction of a second, not the
    /// ~5 s default page timeout, on every single poll.
    private static let pageTimeout: BluetoothHCIPageTimeout = 0x0800

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.mouse-reconnect", qos: .utility)
    /// Needed for the same reason `HotspotFallback` keeps one: IOBluetooth's
    /// synchronous calls still lean on the calling thread's run loop, and a
    /// bare `DispatchQueue` has none.
    private let bluetooth = RunLoopThread(name: "ro.victorrentea.macos-addons.mouse-bluetooth")
    private var timer: DispatchSourceTimer?
    /// Addresses already logged as "unfamiliar" this run, so a mouse left on
    /// a desk doesn't get one log line per poll forever.
    private var loggedUnknown: Set<String> = []

    func start() {
        bluetooth.start()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        overlayInfo("🖱️ Mouse auto-reconnect armed (\(Self.trustedAddresses.count) trusted address(es))")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    /// `GET /test/mouse-reconnect` — run one round right now, whatever the
    /// poll clock says, and report what it found. Short enough (bounded by
    /// `pageTimeout`) to answer synchronously, unlike the phone's RFCOMM open.
    func forceAttemptJSON() -> String {
        let done = DispatchSemaphore(value: 0)
        var connected: [String: Bool] = [:]
        bluetooth.async { [weak self] in
            self?.reconnectTrusted { connected = $0 }
            done.signal()
        }
        _ = done.wait(timeout: .now() + Double(Self.trustedAddresses.count) * 2 + 2)
        let pairs = connected.sorted(by: { $0.key < $1.key })
            .map { "\"\(Self.jsonEscape($0.key))\":\($0.value)" }
            .joined(separator: ",")
        return "{\"enabled\":\(MouseAutoReconnectSettings.isEnabled),\"connected\":{\(pairs)}}"
    }

    // MARK: - Internals

    private func tick() {
        guard MouseAutoReconnectSettings.isEnabled else { return }
        bluetooth.async { [weak self] in self?.reconnectTrusted(nil) }
        logUnknownMice()
    }

    /// Runs on `bluetooth`. Attempts a connection for every trusted address
    /// that is paired but not already connected; silent on failure/absence,
    /// since "not currently in range" is the expected common case every poll.
    private func reconnectTrusted(_ report: (([String: Bool]) -> Void)?) {
        var connected: [String: Bool] = [:]
        for address in Self.trustedAddresses {
            guard let device = IOBluetoothDevice(addressString: address) else {
                connected[address] = false
                continue
            }
            if !device.isConnected() {
                let r = device.openConnection(nil, withPageTimeout: Self.pageTimeout, authenticationRequired: false)
                if r == kIOReturnSuccess, device.isConnected() {
                    overlayInfo("🖱️ Mouse (\(address)) reconnected")
                }
            }
            connected[address] = device.isConnected()
        }
        report?(connected)
    }

    /// Paired devices whose name says "Logi" — the same family as the
    /// trusted mice — but that are not in the allow-list. IOBluetoothDevice
    /// exposes no vendor/product ID of its own (that only comes from
    /// `system_profiler`'s separate IOKit query), so the name is what there
    /// is to go on; this is purely a log line for Victor to act on, never a
    /// basis for connecting. Logged once each, so a genuine replacement
    /// mouse's address is never a guess: it is right there in the log the
    /// first time this app sees it.
    private func logUnknownMice() {
        queue.async { [weak self] in
            guard let self else { return }
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            for device in paired {
                guard let name = device.name, name.localizedCaseInsensitiveContains("logi") else { continue }
                guard let address = device.addressString else { continue }
                guard !Self.trustedAddresses.contains(address), !self.loggedUnknown.contains(address) else { continue }
                self.loggedUnknown.insert(address)
                overlayInfo("🖱️ Unfamiliar '\(name)' paired (\(address)) — add it to MouseAutoReconnect.trustedAddresses if it's Victor's")
            }
        }
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum MouseAutoReconnectSettings {
    static let enabledKey = "MouseAutoReconnect.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
