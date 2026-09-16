import CoreBluetooth
import Foundation
import IOBluetooth

/// Reconnects Victor's own Bluetooth mouse the moment it is back in range,
/// for the case macOS leaves it sitting paired-but-not-connected (observed:
/// System Settings › Bluetooth shows it "Not Connected" with the mouse awake
/// and on the desk — macOS's own auto-reconnect just doesn't always fire).
///
/// ## Why CoreBluetooth, not `IOBluetoothDevice.openConnection()`
///
/// The first version of this class called `IOBluetoothDevice.openConnection`
/// — the same call `HotspotFallback` uses for the phone — and it does not
/// work here: that call issues a classic HCI `CREATE_CONNECTION` (a baseband
/// **page**), and the M650 L is BLE-only (`system_profiler` shows `Services:
/// <BLE>`, no BR/EDR). Measured 15 Sep 2026: the call never returned at all
/// — not even after its own page timeout — and neither did `blueutil
/// --connect` against the same address, which rules out "our code called it
/// wrong" (blueutil is a separate, mature binary hitting the same IOBluetooth
/// API). A classic page has nothing to page; there is no BR/EDR radio on the
/// other end to answer it. So the whole class runs on `CBCentralManager`
/// instead, which is the API family LE peripherals actually connect through.
///
/// ## Why an allow-list of addresses, not a name match
///
/// This Mac has been paired, over time, with **several different physical
/// mice that all report the exact same name** — "Logi M650 L" — because it
/// is the same model bought more than once, and possibly paired during a
/// demo with a trainee's identical mouse. `blueutil --paired` on 15 Sep 2026
/// showed six distinct addresses under that one name. Matching on the name
/// would happily reconnect any of the other five — someone else's mouse, or
/// a dead one from a drawer — which is exactly what "nu te legi de
/// mouse-urile altora" rules out.
///
/// CoreBluetooth itself never reveals a peripheral's Bluetooth address (only
/// a per-app `CBPeripheral.identifier` UUID, for privacy), so the allow-list
/// has to live one layer down, in classic IOBluetooth: `bootstrap()` only
/// ever captures a `CBPeripheral` identity at the moment the **classic**
/// `IOBluetoothDevice` for a trusted address reports itself connected — i.e.
/// only while we already know, by address, that this is Victor's own mouse.
/// From then on the captured `CBPeripheral.identifier` is reused directly
/// (`retrievePeripherals(withIdentifiers:)`), so a later reconnect never has
/// to guess which of the six advertising "Logi M650 L" peripherals is his.
///
/// ## Why the address survives a factory reset
///
/// Resetting the mouse (to pair it to another computer, then back to this
/// Mac) only clears the *bond* — the BLE address is burned into the chip at
/// the factory and does not change. So an address added here stays correct
/// for that physical mouse forever; it is only a genuinely different unit
/// that would need a new entry, and `logUnknownMice()` below prints the
/// address of any such stranger so there is never a guess about what to add.
final class MouseAutoReconnect: NSObject, CBCentralManagerDelegate {
    /// Mice confirmed to be Victor's own. `d8-2e-4e-7e-57-ff` is the one seen
    /// connected on 15 Sep 2026 while this feature was written — add a
    /// sibling here (lowercase, hyphenated, as IOBluetooth prints it) for
    /// every other mouse that is genuinely his; see `logUnknownMice()` for
    /// where an unfamiliar one's address shows up.
    private static let trustedAddresses: Set<String> = [
        "d8-2e-4e-7e-57-ff",
    ]

    /// Services tried, in order, to find the mouse's `CBPeripheral` at
    /// bootstrap time. **Not** the HID service (0x1812): measured 16 Sep
    /// 2026 with the mouse genuinely connected, `retrieveConnectedPeripherals`
    /// under 0x1812 came back empty — macOS's own HID stack apparently keeps
    /// that GATT service to itself. Battery Service (0x180F) and Device
    /// Information (0x180A) both found it; Battery Service is tried first
    /// since practically every BLE mouse reports its battery level.
    private static let bootstrapServiceUUIDs: [CBUUID] = [
        CBUUID(string: "180F"),
        CBUUID(string: "180A"),
    ]
    /// Where the captured `CBPeripheral.identifier` lives once bootstrap has
    /// run — CoreBluetooth hands back the same UUID for the same peripheral
    /// on every future launch, so this only ever has to happen once.
    private static let savedIdentifierKey = "MouseAutoReconnect.peripheralUUID"

    private static let pollInterval: TimeInterval = 20

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.mouse-reconnect", qos: .utility)
    private var central: CBCentralManager!
    /// The one mouse we ever try to connect. `nil` until `bootstrap()` has
    /// captured it — before that there is nothing to reconnect, only
    /// something to wait for.
    private var knownPeripheral: CBPeripheral?
    private var pollTimer: DispatchSourceTimer?
    /// Addresses already logged as "unfamiliar" this run, so a mouse left on
    /// a desk doesn't get one log line per poll forever.
    private var loggedUnknown: Set<String> = []
    /// What the last poll did, for the test hook.
    private var lastState: String = "not started"

    func start() {
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    deinit { stop() }

    /// `GET /test/mouse-reconnect` — run one round right now and report what
    /// it found. Everything here happens async on `queue` via CoreBluetooth
    /// delegate callbacks, so — unlike the phone's RFCOMM open — this reports
    /// the *previous* round's outcome, the same shape `HotspotFallback`'s
    /// hook uses.
    func forceAttemptJSON() -> String {
        queue.async { [weak self] in self?.tick() }
        return queue.sync {
            "{\"enabled\":\(MouseAutoReconnectSettings.isEnabled),\"bootstrapped\":\(knownPeripheral != nil),\"state\":\(Self.jsonString(lastState))}"
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            lastState = "bluetooth adapter not powered on (\(central.state.rawValue))"
            return
        }
        restoreKnownPeripheralIfPossible()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        pollTimer = t
        overlayInfo("🖱️ Mouse auto-reconnect armed (\(Self.trustedAddresses.count) trusted address(es), "
            + (knownPeripheral != nil ? "identity already known" : "waiting to see the mouse connected once") + ")")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        lastState = "connected"
        overlayInfo("🖱️ Mouse reconnected")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastState = "connect failed: \(error?.localizedDescription ?? "unknown error")"
    }

    // MARK: - Internals. All on `queue` (CoreBluetooth's delegate queue).

    private func restoreKnownPeripheralIfPossible() {
        guard let saved = UserDefaults.standard.string(forKey: Self.savedIdentifierKey),
              let uuid = UUID(uuidString: saved) else { return }
        knownPeripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    private func tick() {
        guard MouseAutoReconnectSettings.isEnabled else {
            lastState = "disabled"
            return
        }
        logUnknownMice()
        guard let peripheral = knownPeripheral else {
            bootstrap()
            return
        }
        guard peripheral.state != .connected else {
            lastState = "already connected"
            return
        }
        lastState = "connecting…"
        central.connect(peripheral, options: nil)
    }

    /// Captures the mouse's `CBPeripheral` identity, but only at the moment
    /// its **classic** address — the one thing that actually distinguishes
    /// it from the other five identically-named mice — reports itself
    /// connected. Runs every poll until it succeeds once; after that
    /// `knownPeripheral` is set for the life of the app (and persisted for
    /// every future launch).
    private func bootstrap() {
        guard Self.trustedAddresses.contains(where: { IOBluetoothDevice(addressString: $0)?.isConnected() == true }) else {
            lastState = "not bootstrapped yet — trusted mouse not seen connected since launch"
            return
        }
        var peripheral: CBPeripheral?
        for uuid in Self.bootstrapServiceUUIDs {
            peripheral = central.retrieveConnectedPeripherals(withServices: [uuid]).first
            if peripheral != nil { break }
        }
        guard let peripheral else {
            lastState = "trusted mouse is connected (classic), but CoreBluetooth reports no matching peripheral under any tried service"
            return
        }
        knownPeripheral = peripheral
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedIdentifierKey)
        lastState = "bootstrapped"
        overlayInfo("🖱️ Mouse identity captured for future reconnects (\(peripheral.identifier))")
    }

    /// Paired devices whose name says "Logi" — the same family as the
    /// trusted mice — but that are not in the allow-list. Purely a log line
    /// for Victor to act on, never a basis for connecting. Logged once each,
    /// so a genuine replacement mouse's address is never a guess: it is
    /// right there in the log the first time this app sees it.
    private func logUnknownMice() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in paired {
            guard let name = device.name, name.localizedCaseInsensitiveContains("logi") else { continue }
            guard let address = device.addressString else { continue }
            guard !Self.trustedAddresses.contains(address), !loggedUnknown.contains(address) else { continue }
            loggedUnknown.insert(address)
            overlayInfo("🖱️ Unfamiliar '\(name)' paired (\(address)) — add it to MouseAutoReconnect.trustedAddresses if it's Victor's")
        }
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}

enum MouseAutoReconnectSettings {
    static let enabledKey = "MouseAutoReconnect.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
