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
/// The menu toggle. Default on: the feature is a fallback that does nothing
/// unless the Mac is already offline, so the safe default is armed.
enum HotspotFallbackSettings {
    static let enabledKey = "HotspotFallback.enabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

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

    /// How long we keep polling (and asking to join) after the signal is
    /// delivered. Measured 27 Aug 2026 with the phone's Wi-Fi off beforehand:
    /// **30 s** from channel open to the Mac being online — the routine fires at
    /// once, but a soft-AP that has to tear the STA down first is nowhere near
    /// the ~8 s spin-up measured when Wi-Fi was already on. At 12 s the app gave
    /// up and logged `channel is open but no internet followed` on a run that
    /// then succeeded seconds later, which is a lie in the log at the worst
    /// possible moment. Overshooting costs nothing: the loop exits the second
    /// the probe answers.
    private static let waitAfterPlainConnect = 45
    /// Poll budget after the power cycle (seconds).
    private static let waitAfterPowerCycle = 15

    /// Floor between attempts, so a place with genuinely no coverage doesn't get
    /// an SDP query and a channel open every few seconds for as long as we sit
    /// there.
    ///
    /// It was 180 s, inherited from when the escalation power-cycled the
    /// Bluetooth adapter and a retry was genuinely expensive. What is left is an
    /// SDP query and a channel open, which are not — and 180 s was actively
    /// harmful: **a lid-open landed inside it and did nothing at all.** Observed
    /// live, `📵 No internet (wake) but only 82s since last attempt — holding`,
    /// which from the outside is the feature being broken for a minute and a
    /// half with no hotspot and no explanation.
    private static let cooldown: TimeInterval = 45
    /// A wake is a new room, a new lid-open, a new situation — the exact moment
    /// this feature exists for — so it is not held back by the ordinary floor.
    /// It still gets a small one, because a single wake emits a burst of path
    /// updates behind it.
    private static let wakeCooldown: TimeInterval = 10

    /// When we start *asking* to join rather than waiting for macOS, and how
    /// often after that. The phone needs a couple of seconds to bring the soft
    /// AP up and `-setairportnetwork` against an AP that isn't beaconing yet
    /// simply fails, so there is no point asking instantly; measured, the
    /// routine flips the hotspot 1.5 s after the signal.
    private static let firstJoinAfter: TimeInterval = 4
    private static let joinRetryEvery: TimeInterval = 3

    /// Breathing room for the phone to stand a new listening socket up after we
    /// close a channel ourselves.
    private static let reopenSettle: TimeInterval = 2

    /// Total budget for one SDP-query + open (+ one retry after a fresh query).
    /// Generous, because it is paid only when we already know we are offline.
    private static let channelOpenBudget: TimeInterval = 40

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
    private let geofence = HomeGeofence()
    private var opener: ChannelOpener?
    /// What the last channel open did, for the test hook to report.
    private var lastChannelError: String?
    private var lastChannelAt: Date?
    /// IOBluetooth's async callbacks are delivered on the run loop of the thread
    /// that started the operation, and a `DispatchQueue` has no run loop — which
    /// is why the first version could not hear `rfcommChannelOpenComplete` at
    /// all. The main thread does have one, but an SDP query plus a channel open
    /// plus a retry is up to 20 seconds, and the menu bar (and the `/test/*`
    /// HTTP handler, which runs there) must not be held that long.
    private let bluetooth = RunLoopThread(name: "ro.victorrentea.macos-addons.bluetooth")

    func start() {
        bluetooth.start()
        pathMonitor.pathUpdateHandler = { [weak self] _ in self?.scheduleEvaluation(reason: "network change") }
        pathMonitor.start(queue: queue)

        // Waking is the moment this exists for: the lid opens in a new room and
        // the answer is wanted before the first page load. It also usually gives
        // us a free edge, since sleeping drops the Bluetooth link — so the cheap
        // stage is normally enough and the mouse never notices.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.scheduleEvaluation(reason: "wake") }

        geofence.start()
        overlayInfo("📶 Hotspot fallback armed (phone \(Self.phoneBluetoothAddress), grace \(Int(Self.grace))s)")
    }

    /// `GET /test/hotspot` — run the phone half of the chain *now*, whatever the
    /// Mac's connectivity, whether or not we are at home, and regardless of the
    /// cooldown. Only the RFCOMM open is forced: the routine on the phone still
    /// has to do its own part, which is precisely what this is for testing.
    ///
    /// It exists because the honest test used to be "take the Mac somewhere with
    /// no Wi-Fi and wait", and a chain that fails silently cannot be debugged
    /// that way — the bug this was written for survived weeks of looking healthy.
    /// The attempt runs in the background — an SDP query and a channel open far
    /// outlast an HTTP response, and this handler is on the main thread — so the
    /// snapshot describes the **previous** attempt. Call it twice: the first call
    /// starts one, the second reports how it went.
    func forceAttemptJSON() -> String {
        let snapshot = queue.sync { () -> String in
            var parts: [String] = []
            parts.append("\"last_channel_open\":\(lastChannelAt != nil && lastChannelError == nil)")
            parts.append("\"last_error\":\(Self.jsonString(lastChannelError ?? ""))")
            parts.append("\"last_attempt_at\":\(Self.jsonString(lastChannelAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""))")
            parts.append("\"channel_is_open\":\(channel?.isOpen() ?? false)")
            parts.append("\"at_home\":\(geofence.isAtHome())")
            parts.append("\"enabled\":\(HotspotFallbackSettings.isEnabled)")
            return "{\(parts.joined(separator: ","))}"
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.lastAttemptAt = Date()
            let err = self.openChannel()
            if let err {
                overlayError("📵 /test/hotspot — \(err)")
            } else {
                overlayInfo("📶 /test/hotspot — channel open, the phone's routine should be firing now")
            }
        }
        return snapshot
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
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

        guard HotspotFallbackSettings.isEnabled else {
            overlayInfo("📵 No internet (\(reason)) — but the hotspot fallback is switched off in the menu")
            return
        }
        // Asked only once we already know there is no internet: a location fix
        // costs radios and a menu-bar app sees network changes all day.
        if geofence.isAtHome() {
            overlayInfo("🏠 No internet (\(reason)) — but we are at home, so this stays manual")
            return
        }

        // A wake gets the short floor; everything else gets the ordinary one.
        let floor = reason == "wake" ? Self.wakeCooldown : Self.cooldown
        let since = Date().timeIntervalSince(lastAttemptAt)
        guard since >= floor else {
            overlayInfo("📵 No internet (\(reason)) but only \(Int(since))s of \(Int(floor))s since last attempt — holding")
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
    /// **The clock is the wall clock, not the iteration count**, and that is not
    /// a detail. This loop used to count its own turns and call them seconds,
    /// but each turn is a 1 s sleep *plus* a probe that blocks for up to 2 s
    /// whenever we are offline — which here is always, since being offline is
    /// the premise. So a turn was ~3 s, "join at 6 s" happened at about 18 s,
    /// and a 45 s budget was really 135 s.
    ///
    /// Measured cost of that, end to end: the phone had the hotspot up **1.5 s**
    /// after the signal, and the Mac sat there not asking to join it for another
    /// **25 s** — three quarters of the whole recovery, spent waiting on a
    /// counter that was lying about what it counted.
    private func waitForInternet(seconds: Int, stage: String) -> Bool {
        let began = Date()
        var lastJoinError: String?
        var nextJoinAt: TimeInterval = Self.firstJoinAfter
        func elapsed() -> TimeInterval { Date().timeIntervalSince(began) }

        while elapsed() < Double(seconds) {
            Thread.sleep(forTimeInterval: 1)
            if hasInternet() {
                lastKnownOnline = true
                overlayInfo("📶 Online after \(Int(elapsed()))s (\(stage))")
                return true
            }
            guard elapsed() >= nextJoinAt else { continue }
            nextJoinAt = elapsed() + Self.joinRetryEvery
            let err = Self.joinHotspot()
            if err == nil {
                overlayInfo("📶 Joined '\(Self.hotspotSSID)' at \(Int(elapsed()))s (\(stage))")
            } else if err != lastJoinError {
                lastJoinError = err
                overlayInfo("📵 Join '\(Self.hotspotSSID)' refused at \(Int(elapsed()))s: \(err!)")
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
    /// **The channel number is not stable and the stale one fails silently.**
    /// The phone re-creates its listening socket after every connection, and the
    /// Bluetooth stack hands the new socket a *different* RFCOMM channel — so the
    /// number that worked last time is wrong from then on. macOS caches the SDP
    /// record, `getServiceRecord` happily returns the cached one, and an open
    /// against a channel nobody is listening on fails *asynchronously*, in a
    /// delegate callback. The first version had no such callback, so it logged
    /// "channel open" and returned success every single time. Measured, that is
    /// exactly what happened: the chain worked once (channel 10), the phone then
    /// re-listened on channel 9, and every attempt after that opened nothing at
    /// all while reporting success — the hotspot simply never came on again.
    ///
    /// So this waits for `rfcommChannelOpenComplete`, and on failure re-runs the
    /// SDP query and retries with whatever channel the phone is on *now*.
    ///
    /// IOBluetooth delivers those callbacks on the run loop of the thread that
    /// started the operation, and `queue` has no run loop — which is why the work
    /// is kicked onto the main thread and awaited here with a semaphore rather
    /// than driven from `queue` directly. (The same missing run loop is why
    /// `openRFCOMMChannelSync` with a nil delegate fails with a bare
    /// `kIOReturnError`.) The channel is held in a property because releasing it
    /// closes it, and a closed channel is no signal at all.
    private func openChannel() -> String? {
        // A fresh open, so the phone sees a fresh connection. If we are the ones
        // dropping the old channel, give the phone a moment: its accept loop
        // closes the old socket and stands a new one up, and a query fired into
        // that window reads a record that is about to stop being true.
        let hadChannel = channel != nil
        closeChannel()
        if hadChannel { Thread.sleep(forTimeInterval: Self.reopenSettle) }

        var result: String? = "the phone never answered the channel open"
        let done = DispatchSemaphore(value: 0)
        var signalled = false
        let finish: (String?) -> Void = { why in
            guard !signalled else { return }
            signalled = true
            result = why
            done.signal()
        }

        bluetooth.async { [weak self] in
            guard let self else { return finish("the app is shutting down") }
            guard let dev = IOBluetoothDevice(addressString: Self.phoneBluetoothAddress) else {
                return finish("phone not in the Bluetooth pairing list")
            }
            let opener = ChannelOpener(device: dev, sppUUID: Self.sppUUID) { [weak self] outcome in
                switch outcome {
                case .opened(let ch, let chID):
                    self?.channel = ch
                    overlayInfo("📶 RFCOMM channel open to the phone (channel \(chID))")
                    finish(nil)
                case .failed(let why):
                    self?.opener = nil
                    finish(why)
                }
            }
            self.opener = opener
            opener.start()
        }

        _ = done.wait(timeout: .now() + Self.channelOpenBudget)
        lastChannelAt = Date()
        lastChannelError = result
        return result
    }

    private func closeChannel() {
        channel?.close()
        channel = nil
        opener = nil
    }

    /// Runs one SDP query + RFCOMM open against the phone, on the main thread's
    /// run loop, and reports what actually happened — including a retry with a
    /// freshly queried channel number when the first open is refused.
    ///
    /// It is also the channel's delegate, and it is retained by `HotspotFallback`
    /// for as long as the channel is meant to stay up: IOBluetooth does not
    /// retain the delegate, and a deallocated delegate takes the channel with it.
    private final class ChannelOpener: NSObject, IOBluetoothRFCOMMChannelDelegate {
        enum Outcome {
            case opened(IOBluetoothRFCOMMChannel, BluetoothRFCOMMChannelID)
            case failed(String)
        }

        /// Page timeout for bringing the baseband link up, in 0.625 ms slots:
        /// 0x2000 ≈ 5.1 s. Measured cold, the phone answers in 4.0 s.
        private static let pageTimeout: BluetoothHCIPageTimeout = 0x2000

        /// How long the phone gets to answer one SDP query.
        ///
        /// 6 s was too tight and produced a false negative on the first
        /// automatic attempt of a real test: a query answers in about a second
        /// once the ACL link is up, but when it is cold the phone has to be
        /// paged first, and that is where the seconds go. This is paid only when
        /// the phone is genuinely unreachable.
        private static let sdpTimeout: TimeInterval = 15

        private let device: IOBluetoothDevice
        private let sppUUID: UInt16
        private var report: ((Outcome) -> Void)?
        private var channel: IOBluetoothRFCOMMChannel?
        private var channelID: BluetoothRFCOMMChannelID = 0
        /// One retry, and only after a *fresh* SDP query — the whole point is to
        /// stop trusting a channel number that has gone stale.
        private var triesLeft = 2
        private var sdpWatchdog: Timer?

        init(device: IOBluetoothDevice, sppUUID: UInt16, report: @escaping (Outcome) -> Void) {
            self.device = device
            self.sppUUID = sppUUID
            self.report = report
        }

        func start() { querySDP() }

        private func finish(_ outcome: Outcome) {
            sdpWatchdog?.invalidate()
            sdpWatchdog = nil
            let r = report
            report = nil
            r?(outcome)
        }

        /// **The link has to be up before the SDP query, or the query never
        /// comes back at all.** Measured 27 Aug 2026, with the adapter
        /// power-cycled to imitate a lid-close: `performSDPQuery` returns
        /// `kIOReturnSuccess` and `sdpQueryComplete` then simply never fires —
        /// 42 s and counting. macOS will not page the phone on an SDP query's
        /// behalf. `openConnection()` will, and takes **4.0 s** from cold; after
        /// it the query answers in 0.0 s and the channel opens in 0.2 s.
        ///
        /// This is exactly what a lid-open hits, and it is why the chain kept
        /// failing in the one situation it exists for while working perfectly
        /// whenever it was tested with the link already warm.
        private func querySDP() {
            guard triesLeft > 0 else {
                return finish(.failed("the phone refused the RFCOMM channel twice"))
            }
            triesLeft -= 1

            if !device.isConnected() {
                let began = Date()
                // Bounded, so a phone that is out of range or switched off costs
                // one page timeout rather than blocking this thread indefinitely.
                let r = device.openConnection(nil, withPageTimeout: Self.pageTimeout, authenticationRequired: false)
                let took = String(format: "%.1f", Date().timeIntervalSince(began))
                guard r == kIOReturnSuccess else {
                    return finish(.failed("the phone did not answer the Bluetooth page in \(took)s (\(r)) — out of range or switched off?"))
                }
                overlayInfo("📶 Bluetooth link to the phone up in \(took)s")
            }

            // A query that never comes back would otherwise hang the attempt for
            // the whole outer budget with nothing in the log to say why.
            sdpWatchdog = Timer.scheduledTimer(withTimeInterval: Self.sdpTimeout, repeats: false) { [weak self] _ in
                self?.finish(.failed("the phone did not answer the SDP query in \(Int(Self.sdpTimeout))s"))
            }
            let status = device.performSDPQuery(self)
            if status != kIOReturnSuccess {
                finish(.failed("performSDPQuery failed (\(status))"))
            }
        }

        /// `IOBluetoothDeviceAsyncCallbacks` — the SDP cache has just been
        /// refreshed, so this is the first moment the channel number can be
        /// trusted.
        @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
            sdpWatchdog?.invalidate()
            sdpWatchdog = nil
            guard status == kIOReturnSuccess else {
                return finish(.failed("SDP query failed (\(status)) — is the phone in range?"))
            }
            guard let rec = self.device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: sppUUID)) else {
                return finish(.failed("the phone is not publishing the SPP channel — is victor-phone-addons running?"))
            }
            var chID: BluetoothRFCOMMChannelID = 0
            guard rec.getRFCOMMChannelID(&chID) == kIOReturnSuccess, chID != 0 else {
                return finish(.failed("the SPP record carries no RFCOMM channel number"))
            }
            channelID = chID

            var ch: IOBluetoothRFCOMMChannel?
            let r = self.device.openRFCOMMChannelAsync(&ch, withChannelID: chID, delegate: self)
            guard r == kIOReturnSuccess, let ch else {
                return finish(.failed("openRFCOMMChannelAsync failed on channel \(chID) (\(r))"))
            }
            channel = ch
        }

        func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
            guard status == kIOReturnSuccess else {
                // Re-querying on its own would not help: with the link up, macOS
                // answers an SDP query out of its own cache in 0.0 s — the same
                // cache that just gave us a number nobody is listening on. The
                // link has to go down and come back for the record to be fetched
                // from the phone again.
                overlayInfo("📵 channel \(channelID) refused (\(status)) — dropping the link to re-read the phone's SDP record")
                channel = nil
                device.closeConnection()
                return querySDP()
            }
            guard let ch else { return finish(.failed("channel opened with no channel object")) }
            finish(.opened(ch, channelID))
        }

        func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
            overlayInfo("📵 RFCOMM channel to the phone closed")
        }

        func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {}
    }
}
