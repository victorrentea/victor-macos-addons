import Foundation
import IOKit

/// Keeps the tablet⇄Mac **USB tunnel** armed so the Android LaunchBreak tablet
/// can reach the Mac's HTTP server at `localhost:55123` even with **no shared
/// WiFi** — the wired backup path.
///
/// The tablet's `MacLink` pings both `Victor-Mac.local:55123` (WiFi/mDNS) and
/// `localhost:55123` (USB via `adb reverse`), always *preferring WiFi* and only
/// falling back to USB when WiFi is down. So there is no need to detect the
/// WiFi state (which the Mac can't observe from the tablet's side anyway):
/// arming the reverse rule whenever the cable is plugged in is free and gives a
/// transparent, always-ready backup.
///
/// **Two mechanisms, one goal.** The reverse rule is (re)armed by
/// *both* an OS-level USB-attach hook and a periodic poll:
///
/// 1. **USB-attach hook (fast path).** An IOKit `kIOFirstMatchNotification`
///    fires the instant a matching ADB interface enumerates — the moment the
///    cable is plugged in. On that edge we immediately (re)run `adb reverse`
///    with a short retry burst (adbd is usually mid-handshake right after
///    enumeration), so a mid-talk replug is armed in well under a second
///    instead of waiting up to a full poll interval.
/// 2. **Poll (healing path).** A power-aware timer that catches everything the
///    edge hook can miss: the adb *server* restarting under us, a
///    notification we didn't get, or arming a device that was already plugged
///    in at launch.
///
/// **Cheap poll.** Presence is checked *in-process* via IOKit — we match an
/// `IOUSBHostInterface` carrying the ADB class triplet (class 255 / subclass 66
/// / protocol 1), a Mach call that costs microseconds and spawns nothing. The
/// (relatively) expensive `adb reverse` process is spawned **only** when the
/// rule is actually missing, and retried on later ticks until it sticks (USB
/// enumerates before adbd finishes its handshake). `start.sh` still arms it once
/// at launch; this keeps it armed when the cable is plugged in mid-session.
///
/// **The poll verifies, it does not assume.** While armed, each tick spends one
/// cheap `adb reverse --list` confirming the rule is still in adb's table. That
/// costs a process spawn every 30 s on AC, and it is the whole point of the
/// poll: the rule can disappear with the cable never touched — `adb
/// kill-server`, `adb reverse --remove-all`, a deploy script, Android Studio, or
/// the tablet's own adbd restarting all drop it without an unplug edge, so no
/// notification fires and `armed` stays stale. This class used to short-circuit
/// on that flag and the tunnel then stayed dead for the rest of the session:
/// `MacLink` fell through to the internet relay, which is slow and flaps, so on
/// the tablet every tap did nothing while the header still showed a live link.
/// Believing our own bookkeeping over adb's is what made that invisible.
///
/// **Power-aware cadence:** a lazy **30s heartbeat on AC** (a stable venue with
/// working WiFi rarely needs the wired path) tightening to **5s on battery**
/// (mobile/travel, where WiFi is likelier to drop and the USB backup must come
/// up fast). The interval is re-read from the power source every tick, so it
/// adapts the instant the charger is plugged/unplugged.
///
/// So a rule that drops mid-session without a USB replug is healed by the next
/// poll — within 30 s on AC, 5 s on battery — rather than surviving as a stale
/// belief until someone re-plugs the cable or restarts the app.
final class UsbTunnelKeeper {
    private static let port = 55123
    private static let acInterval = 30       // seconds, on AC power
    private static let batteryInterval = 5   // seconds, on battery
    /// Fast-retry burst fired on the USB-attach edge, to beat the adbd
    /// handshake without waiting for the next poll: attempts spaced `retryStep`
    /// apart, up to `attachRetries` total.
    private static let attachRetries = 8
    private static let retryStep = 400       // milliseconds between edge retries

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.usb-tunnel-keeper", qos: .utility)
    /// IOKit device-attach notification plumbing. The port delivers callbacks on
    /// `queue` (via `IONotificationPortSetDispatchQueue`), so the callback shares
    /// the same serial queue as everything else — no extra locking.
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    /// Whether the reverse rule is set for the *current* USB connection. Reset
    /// when the tablet unplugs. Lives only on `queue`, so reads/writes are
    /// sequential. Logged only when it flips (no per-tick spam).
    private var armed = false
    /// So a phone left on the cable doesn't write the same line every tick.
    private var tabletMissingLogged = false

    /// Fired on the armed edge — the cable is in *and* adb is answering. This is
    /// the moment `AndroidAppDeployer` can talk to the tablet, so it hangs off
    /// here rather than off the raw IOKit attach (where adbd is still
    /// handshaking). Called on `queue`.
    var onTunnelArmed: (() -> Void)?

    /// First adb binary that exists among the known install locations. Prefers
    /// the Android SDK copy `start.sh` uses, so the app and its own startup
    /// script share one adb server (no version thrash). Shared with
    /// `AndroidAppDeployer`, so both speak to the same adb server.
    static let adbPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func start() {
        guard Self.adbPath != nil else {
            NSLog("[UsbTunnelKeeper] adb not found — USB backup disabled")
            return
        }
        scheduleNext(after: 2)
        // Register the USB-attach hook on `queue` so its initial drain (and every
        // later callback) touches `armed` on the same serial queue as the poll.
        queue.async { [weak self] in self?.registerUsbMatchNotification() }
    }

    /// Force an immediate (re)arm of the reverse tunnel now — the same work the
    /// USB-attach hook does. Safe to call from any thread. This is the "reconnect
    /// now" entry point; the tablet's own re-probe complements it from its side.
    func forceReconnectNow() {
        queue.async { [weak self] in self?.forceReconnect() }
    }

    /// Self-rescheduling one-shot so the cadence can change with the power
    /// source between ticks (a fixed `repeating:` timer can't).
    private func scheduleNext(after seconds: Int) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(seconds))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick()
            let next = PowerMonitor.isOnAC() ? Self.acInterval : Self.batteryInterval
            self.scheduleNext(after: next)
        }
        t.resume()
        timer = t
    }

    private func tick() {
        // Free, in-process presence check — no process spawn.
        guard Self.adbDevicePresent() else {
            setArmed(false)
            return
        }
        // The cable is in — but `armed` is only ever a *belief*, and the reverse
        // rule can vanish underneath it with the cable never touched: an
        // `adb kill-server`, a `adb reverse --remove-all`, a deploy script,
        // Android Studio, or the tablet's own adbd restarting all drop the rule
        // without producing an unplug edge. Trusting the flag here is what let
        // the tunnel stay dead for a whole session: `MacLink` then slid onto the
        // internet relay, which is slow and flaps, so tap after tap did nothing
        // while the tablet still showed a connected link. Verify instead.
        if armed, Self.reverseRuleStillArmed() { return }
        if armed {
            NSLog("[UsbTunnelKeeper] reverse rule vanished with the cable still in — re-arming")
            armed = false
        }
        // Plug-in edge (or a retry after adbd wasn't ready yet): (re)establish
        // the reverse rule. A failure here just leaves us disarmed to retry on
        // the next tick.
        attemptArm()
    }

    /// Run `adb reverse` once **against the tablet**; on success flip `armed`
    /// true. Assumes the caller already confirmed a device is present. Returns
    /// whether it stuck.
    ///
    /// The serial is explicit because the IOKit check above only knows that
    /// *some* ADB interface enumerated, and the phone goes on the same cable.
    /// A bare `adb reverse` would then arm a tunnel to the phone — which nothing
    /// on the phone listens to — and, worse, would report the tunnel armed, so
    /// `onTunnelArmed` would fire and hand the phone to `AndroidAppDeployer`.
    @discardableResult
    private func attemptArm() -> Bool {
        guard let adb = Self.adbPath else { return false }
        guard case .tablet(let tablet) = AndroidAppDeployer.tabletSerial() else {
            if !tabletMissingLogged {
                tabletMissingLogged = true
                NSLog("[UsbTunnelKeeper] a device is on USB but it is not the tablet — leaving the tunnel down")
            }
            return false
        }
        tabletMissingLogged = false
        let status = Self.run(adb, ["-s", tablet.serial, "reverse", "tcp:\(Self.port)", "tcp:\(Self.port)"])
        if status == 0 {
            setArmed(true)
            return true
        }
        return false
    }

    /// The USB-attach fast path: a fresh cable means the old reverse rule is gone
    /// with the old connection, so drop `armed` and re-arm now with a short retry
    /// burst (adbd is typically still handshaking right after enumeration). If it
    /// still won't stick, we stop and let the poll heal it. Runs on `queue`.
    private func forceReconnect() {
        guard Self.adbDevicePresent() else {
            setArmed(false)
            return
        }
        armed = false
        tabletMissingLogged = false   // a fresh cable deserves a fresh verdict
        armWithRetries(attemptsLeft: Self.attachRetries)
    }

    private func armWithRetries(attemptsLeft: Int) {
        guard Self.adbDevicePresent() else {
            setArmed(false)
            return
        }
        if armed || attemptArm() { return }
        guard attemptsLeft > 1 else {
            NSLog("[UsbTunnelKeeper] USB attach: adb reverse not ready yet — poll will retry")
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(Self.retryStep)) { [weak self] in
            self?.armWithRetries(attemptsLeft: attemptsLeft - 1)
        }
    }

    // MARK: - USB-attach notification (fast path)

    private static let matchCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let keeper = Unmanaged<UsbTunnelKeeper>.fromOpaque(refcon).takeUnretainedValue()
        keeper.handleUsbMatch(iterator: iterator)
    }

    /// Register a `kIOFirstMatchNotification` for the ADB interface so an attach
    /// re-arms the tunnel immediately, instead of waiting for the next poll.
    /// Called on `queue`; the port delivers later callbacks on `queue` too.
    private func registerUsbMatchNotification() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            NSLog("[UsbTunnelKeeper] could not create IONotificationPort — attach hook disabled")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)
        guard let matching = Self.adbInterfaceMatchingDict() else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching,
            Self.matchCallback,
            refcon,
            &matchIterator
        )
        guard kr == KERN_SUCCESS else {
            NSLog("[UsbTunnelKeeper] IOServiceAddMatchingNotification failed: \(kr) — attach hook disabled")
            return
        }
        // Draining the iterator both arms the notification and reports any device
        // already attached at launch (which we then arm right away).
        handleUsbMatch(iterator: matchIterator)
    }

    /// Drain the iterator (required to re-arm the notification) and, if any ADB
    /// interface appeared, immediately (re)arm the reverse tunnel. Runs on `queue`.
    private func handleUsbMatch(iterator: io_iterator_t) {
        var appeared = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            appeared = true
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        guard appeared else { return }
        forceReconnect()
    }

    private func setArmed(_ value: Bool) {
        guard armed != value else { return }
        armed = value
        NSLog(value
            ? "[UsbTunnelKeeper] USB tunnel armed — tablet reachable at localhost:\(Self.port)"
            : "[UsbTunnelKeeper] USB tunnel down — tablet unplugged")
        if value { onTunnelArmed?() }
    }

    /// A fresh matching dictionary for the standard Android ADB interface:
    /// bInterfaceClass 255 (vendor-specific) / subclass 66 (ADB) / protocol 1.
    /// A new one is built per call because both `IOServiceGetMatchingServices`
    /// and `IOServiceAddMatchingNotification` consume (release) the dictionary.
    private static func adbInterfaceMatchingDict() -> CFDictionary? {
        guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else {
            return nil
        }
        // Property criteria must be nested under kIOPropertyMatchKey — top-level
        // keys are NOT applied by IOServiceGetMatchingServices (they silently
        // yield zero matches).
        matching[kIOPropertyMatchKey] = [
            "bInterfaceClass": 255,    // vendor-specific
            "bInterfaceSubClass": 66,  // ADB
            "bInterfaceProtocol": 1,
        ]
        return matching as CFDictionary
    }

    /// True when an ADB-capable device is on USB, detected purely from the IO
    /// registry (no `adb` spawn).
    private static func adbDevicePresent() -> Bool {
        guard let matching = adbInterfaceMatchingDict() else { return false }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return false
        }
        var service = IOIteratorNext(iter)
        let present = service != 0
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        IOObjectRelease(iter)
        return present
    }

    /// Is the reverse rule *actually* in adb's table right now, as opposed to
    /// merely believed to be? Asks `adb reverse --list`, which is the only
    /// authority — the Mac cannot observe a tablet→Mac tunnel any other way.
    ///
    /// Answers `true` when the question cannot be put (no adb binary, no tablet
    /// among the attached devices, the query itself failed): an adb that cannot
    /// answer is also an adb that cannot re-arm, so claiming the rule is gone
    /// would only spawn a doomed `adb reverse` on every tick. The next tick asks
    /// again. Note that an adb *server* that was killed answers this fine — the
    /// client restarts it and reports an empty table, which is exactly the
    /// "vanished" verdict we want.
    static func reverseRuleStillArmed() -> Bool {
        guard let adb = adbPath,
              case .tablet(let tablet) = AndroidAppDeployer.tabletSerial(),
              let out = capture(adb, ["-s", tablet.serial, "reverse", "--list"])
        else { return true }
        return ruleListMentionsPort(out, port: port)
    }

    /// Does an `adb reverse --list` body carry the rule for `port`? Split out so
    /// it can be asserted without an adb, a cable or a tablet.
    ///
    /// Matches on the **local** side of the rule (`tcp:<port> tcp:<port>`) rather
    /// than a bare `tcp:<port>` substring, so a rule for some other port that
    /// merely forwards *to* ours cannot be mistaken for ours. Lines look like
    /// `UsbFfs tcp:55123 tcp:55123`.
    static func ruleListMentionsPort(_ listing: String, port: Int) -> Bool {
        listing
            .split(separator: "\n")
            .contains { $0.contains("tcp:\(port) tcp:\(port)") }
    }

    /// Like `run`, but hands back stdout. `nil` when the process could not be
    /// launched or exited non-zero — the caller must not read a failed query as
    /// a meaningful empty answer.
    private static func capture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Read before waiting: a pipe filled past its buffer would otherwise
        // deadlock a process we are blocking on.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
