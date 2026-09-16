import CoreBluetooth
import Foundation

/// 🖱️ **Reconnect Mouse** — the menu row that connects a Logi mouse that is
/// switched on and nearby but left sitting "Not Connected" in System
/// Settings › Bluetooth, which macOS does from time to time.
///
/// ## Manual on purpose
///
/// There is deliberately **no automatic path** — no timer, no watcher, no
/// setting. An automatic version was written first and thrown away: a mouse
/// that reconnects the instant it is seen is exactly wrong when the reason it
/// is disconnected is that Victor has just put it on another computer. The
/// only trigger is the click, which is also the moment the intent is known.
///
/// ## Why CoreBluetooth, not `IOBluetoothDevice.openConnection()`
///
/// `openConnection` issues a classic HCI `CREATE_CONNECTION` (a BR/EDR
/// **page**) and the M650 L is BLE-only (`system_profiler`: `Services:
/// <BLE>`). Measured 15 Sep 2026: the call never returned at all, well past
/// its own page timeout — and neither did `blueutil --connect` against the
/// same address, which rules out "our code called it wrong". A classic page
/// has nothing to page. `CBCentralManager` is the API family LE peripherals
/// actually connect through, and its `connect` is properly asynchronous.
///
/// ## Why any Logi mouse, and not one specific address
///
/// An earlier version kept an allow-list of Bluetooth addresses, so it could
/// never grab a stranger's identical mouse — this Mac has been paired with
/// **seven** different addresses all named "Logi M650 L". That turned out to
/// be unworkable *and* unnecessary:
///
/// - **Unworkable**: the addresses drift. Victor confirmed 16 Sep 2026 that
///   two of them (`…57-ff` and `…58-00`) are the same physical mouse — it
///   appears under a new address after being paired to another computer and
///   back, so a pinned address goes stale exactly when the button is needed.
/// - **Unnecessary**: the click *is* the consent. A scan picks the strongest
///   signal (`RSSI`), which is the mouse on this desk rather than one across
///   a training room, and if the wrong one ever answered, the person holding
///   the mouse finds out within a second and clicks again.
final class MouseReconnect: NSObject, CBCentralManagerDelegate {
    /// Substring a peripheral's advertised name must contain. "Logi" covers
    /// every Logitech mouse this has to deal with without matching phones,
    /// speakers or headsets.
    private static let nameMatch = "logi"
    /// How long to listen for advertisements before picking the best one.
    /// A bonded BLE mouse that is awake advertises every few hundred ms, so
    /// this is generous; it is also the floor on how long the click takes.
    private static let scanSeconds: TimeInterval = 6
    /// CoreBluetooth's `connect` never times out on its own — a peripheral
    /// that stops answering leaves the attempt pending forever — so the
    /// click needs its own deadline, or it would never report anything.
    private static let connectSeconds: TimeInterval = 8
    /// Services that find an already-connected mouse. **Not** the HID
    /// service (0x1812): measured 16 Sep 2026 with the mouse genuinely
    /// connected, `retrieveConnectedPeripherals` under 0x1812 came back
    /// empty — macOS's own HID stack keeps that GATT service to itself.
    /// Battery Service and Device Information both found it.
    private static let connectedLookupUUIDs = [CBUUID(string: "180F"), CBUUID(string: "180A")]

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.mouse-reconnect", qos: .utility)
    private var central: CBCentralManager!
    /// Non-nil only while a click is in flight; also the "one at a time" lock.
    private var completion: ((Bool, String) -> Void)?
    /// Candidates seen during the scan window. Holds strong references:
    /// CoreBluetooth drops a peripheral you do not retain, mid-connect.
    private var candidates: [(peripheral: CBPeripheral, rssi: Int)] = []
    private var connecting: CBPeripheral?
    private var deadline: DispatchWorkItem?

    func start() {
        central = CBCentralManager(delegate: self, queue: queue)
    }

    /// The menu row's action. Answers exactly once, through `completion`.
    func reconnectNow(completion: @escaping (Bool, String) -> Void) {
        queue.async { [weak self] in self?.begin(completion) }
    }

    /// `GET /test/mouse-reconnect` — the same thing without the menu, waiting
    /// for the verdict so a curl reports it directly.
    func forceAttemptJSON() -> String {
        let done = DispatchSemaphore(value: 0)
        var ok = false
        var message = "no answer"
        reconnectNow { result, text in
            ok = result
            message = text
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.scanSeconds + Self.connectSeconds + 2)
        return "{\"ok\":\(ok),\"message\":\(Self.jsonString(message))}"
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name ?? ""
        guard name.localizedCaseInsensitiveContains(Self.nameMatch) else { return }
        guard !candidates.contains(where: { $0.peripheral.identifier == peripheral.identifier }) else { return }
        candidates.append((peripheral, RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        finish(true, "\(peripheral.name ?? "Mouse") conectat")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(false, "conectarea a eșuat: \(error?.localizedDescription ?? "eroare necunoscută")")
    }

    // MARK: - Internals. All on `queue` (CoreBluetooth's delegate queue).

    private func begin(_ completion: @escaping (Bool, String) -> Void) {
        guard central.state == .poweredOn else {
            return completion(false, "Bluetooth-ul nu e pornit")
        }
        guard self.completion == nil else {
            return completion(false, "deja caut un mouse")
        }
        if let connected = connectedLogiMouse() {
            return completion(true, "\(connected.name ?? "Mouse-ul") e deja conectat")
        }
        self.completion = completion
        candidates = []
        central.scanForPeripherals(withServices: nil, options: nil)
        schedule(Self.scanSeconds) { [weak self] in self?.scanWindowElapsed() }
    }

    private func scanWindowElapsed() {
        central.stopScan()
        guard let best = candidates.max(by: { $0.rssi < $1.rssi })?.peripheral else {
            return finish(false, "niciun mouse Logi nu e disponibil în apropiere")
        }
        connecting = best
        central.connect(best, options: nil)
        schedule(Self.connectSeconds) { [weak self] in
            self?.finish(false, "mouse-ul a fost văzut, dar nu a răspuns la conectare")
        }
    }

    /// An already-connected Logi mouse, if there is one — the answer to a
    /// click that had nothing to do.
    private func connectedLogiMouse() -> CBPeripheral? {
        for uuid in Self.connectedLookupUUIDs {
            let match = central.retrieveConnectedPeripherals(withServices: [uuid])
                .first { ($0.name ?? "").localizedCaseInsensitiveContains(Self.nameMatch) }
            if let match { return match }
        }
        return nil
    }

    private func schedule(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        deadline?.cancel()
        let work = DispatchWorkItem(block: block)
        deadline = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func finish(_ ok: Bool, _ message: String) {
        deadline?.cancel()
        deadline = nil
        central.stopScan()
        if !ok, let connecting { central.cancelPeripheralConnection(connecting) }
        connecting = nil
        candidates = []
        let answer = completion
        completion = nil
        overlayInfo("🖱️ Reconnect Mouse — \(message)")
        answer?(ok, message)
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
