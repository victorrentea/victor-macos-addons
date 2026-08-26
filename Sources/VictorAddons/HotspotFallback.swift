import AppKit
import Foundation
import IOBluetooth
import Network

/// Brings the phone's Wi-Fi hotspot up when this Mac is left without internet,
/// so a room with no usable Wi-Fi costs a few seconds instead of picking up the
/// phone and toggling the tile by hand.
///
/// ## Why Bluetooth is the trigger and not the transport
///
/// Nothing here carries data over Bluetooth — Apple removed Bluetooth PAN
/// tethering in Monterey, so a Mac cannot get bytes off an Android phone that
/// way at all. Bluetooth is used purely as an **out-of-band signal**, which is
/// the one channel still available when there is no network by definition:
///
/// ```
/// Mac has no internet → blueutil --connect <phone>
///                     → S24 sees "Victor's Mac connected"
///                     → Samsung "Modes and Routines" turns Mobile Hotspot on
///                     → Mac auto-joins 'victor', a known network
/// ```
///
/// The hotspot is flipped by Samsung's own Routines app, which is a system app
/// holding `TETHER_PRIVILEGED`. Nothing is installed on the phone. That detour
/// exists because a sideloaded app *cannot* do it: `startTethering()` has been
/// `signature|privileged` since Android 11, and while `com.android.shell` does
/// hold `TETHER_PRIVILEGED` on this device, `cmd wifi start-softap` is gated on
/// **root uid** inside `WifiShellCommand`, so even ADB cannot reach it.
///
/// ## Why the escalation, and why it is two stages
///
/// The routine fires on the **edge** of the Bluetooth connection, not on the
/// state. That matters because `blueutil --disconnect` turns out not to drop the
/// link at all (measured: exit 0, and the phone still reports `ACL BR/EDR:Y`
/// twelve seconds later at 1 s polling). So if the link is already up, a plain
/// `--connect` is a no-op and produces no edge for the routine to catch.
///
/// Stage one is still the plain connect, because it is free and it *does* fire
/// whenever the link genuinely dropped — which is the common case here, since
/// sleeping the Mac drops it. Only when that produces nothing do we escalate to
/// power-cycling the adapter, which reliably breaks and remakes the link.
///
/// The power cycle is deliberately last: it briefly kills **every** Bluetooth
/// device, and a mouse dying under the hand is a real cost to pay for a
/// speculative reconnect. Measured, it is cheap in time — 1 s until the phone
/// sees the link drop, 1 s until the adapter is back — and the total from edge
/// to working internet is ~10 s, of which ~8 s is the Samsung hotspot spinning
/// up and is irreducible.
///
/// ## Why connectivity, not SSID
///
/// The obvious check — "are we associated with a Wi-Fi network?" — cannot be
/// used. On current macOS, reading the SSID requires Location Services, and a
/// process without that permission is told the SSID is empty *even while fully
/// connected*: `networksetup -getairportnetwork en0` returns nothing while the
/// default route sits on the hotspot's gateway. A first version of this trusted
/// that signal and fired the whole escalation against a healthy connection. So
/// the verdict is a real TCP probe, and this class never needs to know which
/// network it is on — which network to *prefer* is macOS's job, decided by the
/// order of the preferred-networks list.
final class HotspotFallback {

    /// The phone, as IOBluetooth addresses it (Victor S24u).
    private static let phoneBluetoothAddress = "a8-ba-69-cf-8d-58"
    /// Serial Port Profile. The phone publishes an RFCOMM channel under it —
    /// see the `victor-phone-addons` repo — and connecting to that channel is
    /// the whole signal.
    private static let sppUUID: UInt16 = 0x1101

    /// The hotspot's SSID, and the Wi-Fi interface to put on it. Not a secret —
    /// the password is not here and must never be: this repo is public. The join
    /// normally needs no password at all (the keychain already holds one under
    /// service `AirPort`, account `victor`); `HOTSPOT_PASSWORD` in
    /// `~/.training-assistants-secrets.env` is only a fallback for when that
    /// entry is missing.
    private static let hotspotSSID = "victor"
    private static let wifiInterface = "en0"

    /// How long macOS is left alone to join a known network on its own before we
    /// conclude there isn't one. Short, because it is paid on every wake in a
    /// room that has no Wi-Fi, and macOS re-associates with an in-range known AP
    /// well inside it.
    private static let grace: TimeInterval = 4

    /// Poll budget after a plain `--connect` (seconds). Covers the ~8 s hotspot
    /// spin-up with room to spare; overshooting only delays the escalation.
    private static let waitAfterPlainConnect = 12
    /// Poll budget after the power cycle (seconds).
    private static let waitAfterPowerCycle = 15

    /// Floor between attempts. Somewhere with genuinely no coverage, retrying
    /// tight would power-cycle Bluetooth every few seconds for as long as we
    /// stay there.
    private static let cooldown: TimeInterval = 180

    private static let probeHost = "1.1.1.1"
    private static let probePort: NWEndpoint.Port = 443
    private static let probeTimeout: TimeInterval = 2

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.hotspot-fallback", qos: .utility)
    /// The probe gets its own queue, and that is not a detail. `queue` is serial
    /// and `hasInternet()` blocks on it waiting for the handshake — so running
    /// the connection's state handler there too deadlocks it: the handler can
    /// never be dispatched, the semaphore always times out, and every probe
    /// reports "offline". Which is worse than it sounds, because the failure is
    /// silent and self-confirming: on a perfectly healthy connection the first
    /// evaluation after launch declared no internet and power-cycled Bluetooth.
    private let probeQueue = DispatchQueue(label: "ro.victorrentea.macos-addons.hotspot-fallback.probe", qos: .utility)
    private let pathMonitor = NWPathMonitor()

    /// Serialised on `queue`.
    private var lastAttemptAt = Date.distantPast
    private var attemptInFlight = false
    private var pendingEvaluation: DispatchWorkItem?
    /// Transition-only logging: a path change that leaves us online is the
    /// overwhelmingly common case and must not write a line every time.
    private var lastKnownOnline: Bool?
    private var channel: IOBluetoothRFCOMMChannel?
    private var keeper: ChannelKeeper?

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in self?.scheduleEvaluation(reason: "network change") }
        pathMonitor.start(queue: queue)

        // Waking is the moment this exists for: the lid opens in a new room and
        // the answer is wanted before the first page load. It also usually gives
        // us a free edge, since sleeping drops the Bluetooth link — so the cheap
        // stage is normally enough and the mouse never notices.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.scheduleEvaluation(reason: "wake") }

        overlayInfo("📶 Hotspot fallback armed (phone \(Self.phoneBluetoothAddress), grace \(Int(Self.grace))s)")
    }

    /// Debounced: a single wake or reconnect emits a burst of path updates, and
    /// each one would otherwise start its own grace timer.
    private func scheduleEvaluation(reason: String) {
        queue.async { [weak self] in
            guard let self, !self.attemptInFlight else { return }
            self.pendingEvaluation?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.evaluate(reason: reason) }
            self.pendingEvaluation = work
            self.queue.asyncAfter(deadline: .now() + Self.grace, execute: work)
        }
    }

    private func evaluate(reason: String) {
        if hasInternet() {
            if lastKnownOnline != true {
                lastKnownOnline = true
                overlayInfo("📶 Online (\(reason)) — hotspot not needed")
            }
            return
        }
        lastKnownOnline = false

        let since = Date().timeIntervalSince(lastAttemptAt)
        guard since >= Self.cooldown else {
            overlayInfo("📵 No internet (\(reason)) but only \(Int(since))s since last attempt — holding")
            return
        }
        lastAttemptAt = Date()
        attemptInFlight = true
        defer { attemptInFlight = false }

        overlayInfo("📵 No internet after \(Int(Self.grace))s (\(reason)) — asking the phone for its hotspot")

        if let err = openChannel() {
            overlayError("📵 Hotspot fallback failed — \(err)")
            return
        }
        if waitForInternet(seconds: Self.waitAfterPlainConnect, stage: "rfcomm") { return }
        overlayError("📵 Hotspot fallback failed — channel is open but no internet followed")
    }

    /// Polls once a second, and from the 6th second on also *asks* to join the
    /// hotspot rather than waiting for macOS to do it.
    ///
    /// Waiting was the original design and it does not hold up. Auto-join is
    /// opaque — it depends on the network's stored auto-join flag and on where
    /// it sits in a 113-entry preferred list, both of which can silently stop
    /// being what you think they are (observed live: the hotspot was up and
    /// visible in the Wi-Fi menu, and the Mac sat there unassociated until it
    /// was clicked by hand). Asking is deterministic, and it also makes the
    /// preferred-list order irrelevant: we only ever join the hotspot at a
    /// moment when we have already established there is no internet, so it
    /// cannot steal the Mac away from a venue network.
    ///
    /// The first attempt waits ~6 s because the hotspot needs ~8 s to become
    /// joinable and `-setairportnetwork` against an AP that isn't beaconing yet
    /// just fails; retrying every 3 s covers the spread.
    ///
    /// This is also the only thing that tells the two failure modes apart. "The
    /// network could not be found" means the phone never turned the hotspot on
    /// and the routine is at fault; a join that succeeds but leaves us offline
    /// means the hotspot is up and its own uplink is the problem.
    private func waitForInternet(seconds: Int, stage: String) -> Bool {
        var lastJoinError: String?
        for elapsed in 1...seconds {
            Thread.sleep(forTimeInterval: 1)
            if hasInternet() {
                lastKnownOnline = true
                overlayInfo("📶 Online after \(elapsed)s (\(stage))")
                return true
            }
            if elapsed >= 6, elapsed % 3 == 0 {
                let err = Self.joinHotspot()
                if err == nil {
                    overlayInfo("📶 Joined '\(Self.hotspotSSID)' at \(elapsed)s (\(stage))")
                } else if err != lastJoinError {
                    lastJoinError = err
                    overlayInfo("📵 Join '\(Self.hotspotSSID)' refused at \(elapsed)s: \(err!)")
                }
            }
        }
        return false
    }

    /// Asks macOS to associate with the hotspot. Returns `nil` on success, or
    /// the reason it refused.
    ///
    /// `networksetup -setairportnetwork` **exits 0 even when it fails** and
    /// reports the failure only as text on stdout, so the exit status cannot be
    /// trusted here — success is empty output.
    private static func joinHotspot() -> String? {
        var args = ["-setairportnetwork", wifiInterface, hotspotSSID]
        // Normally unnecessary: the keychain holds this network's password
        // already. Only used if that entry has gone missing.
        if let pw = SecretsLoader.load()["HOTSPOT_PASSWORD"], !pw.isEmpty { args.append(pw) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "networksetup failed to launch" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// A real TCP handshake, not `NWPath.status`. A captive portal, an
    /// associated-but-dead AP and a hotspot that has auto-slept all report a
    /// satisfied path while carrying nothing — and each of those is precisely a
    /// case where we *do* want to fall back.
    private func hasInternet() -> Bool {
        let conn = NWConnection(
            host: NWEndpoint.Host(Self.probeHost),
            port: Self.probePort,
            using: .tcp
        )
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:   ok = true;  sem.signal()
            case .failed, .cancelled: ok = false; sem.signal()
            default: break
            }
        }
        conn.start(queue: probeQueue)
        _ = sem.wait(timeout: .now() + Self.probeTimeout)
        conn.cancel()
        return ok
    }

    /// Opens (or re-opens) the RFCOMM channel to the phone. Returns `nil` on
    /// success, or the reason it could not.
    ///
    /// `openRFCOMMChannelSync` with a nil delegate fails here with a bare
    /// `kIOReturnError`, reproducibly; the async form with a real delegate
    /// works. The channel is held in a property because releasing it closes it,
    /// and a closed channel is no signal at all.
    private func openChannel() -> String? {
        if channel?.isOpen() == true { closeChannel() }   // a fresh open, so the phone sees a fresh connection

        guard let dev = IOBluetoothDevice(addressString: Self.phoneBluetoothAddress) else {
            return "phone not in the Bluetooth pairing list"
        }
        // Without a fresh SDP query the channel ID can come from a stale cache —
        // the phone's service is re-registered on every reconnect, and its
        // channel number is not promised to be stable.
        _ = dev.performSDPQuery(nil)
        Thread.sleep(forTimeInterval: 3)

        guard let rec = dev.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: Self.sppUUID)) else {
            return "the phone is not publishing the SPP channel — is victor-phone-addons running?"
        }
        var chID: BluetoothRFCOMMChannelID = 0
        rec.getRFCOMMChannelID(&chID)

        let del = ChannelKeeper()
        var ch: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&ch, withChannelID: chID, delegate: del)
        guard r == kIOReturnSuccess, let ch else { return "openRFCOMMChannelAsync failed (\(r))" }
        keeper = del
        channel = ch
        overlayInfo("📶 RFCOMM channel open to the phone (channel \(chID))")
        return nil
    }

    private func closeChannel() {
        channel?.close()
        channel = nil
        keeper = nil
    }

    /// Holds the channel's delegate. IOBluetooth does not retain it, and a
    /// deallocated delegate takes the channel down with it.
    private final class ChannelKeeper: NSObject, IOBluetoothRFCOMMChannelDelegate {
        func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {}
    }
}
