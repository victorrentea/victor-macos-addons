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
/// (relatively) expensive `adb reverse` process is spawned **only on the plug-in
/// edge** (absent→present), and retried on later ticks until it sticks (USB
/// enumerates before adbd finishes its handshake). While the tablet sits
/// plugged in and armed, each tick is just a free IOKit read — zero `adb`
/// spawns. `start.sh` still arms it once at launch; this keeps it armed when the
/// cable is plugged in mid-session.
///
/// **Power-aware cadence:** a lazy **30s heartbeat on AC** (a stable venue with
/// working WiFi rarely needs the wired path) tightening to **5s on battery**
/// (mobile/travel, where WiFi is likelier to drop and the USB backup must come
/// up fast). The interval is re-read from the power source every tick, so it
/// adapts the instant the charger is plugged/unplugged.
///
/// Caveat: if the adb *server* restarts mid-session without a USB replug, the
/// reverse rule can drop while we still believe we're armed — the poll re-arms
/// it (within one interval), or re-plugging the cable / restarting the app does.
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

    /// First adb binary that exists among the known install locations. Prefers
    /// the Android SDK copy `start.sh` uses, so the app and its own startup
    /// script share one adb server (no version thrash).
    private static let adbPath: String? = {
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
        // Tablet is on USB. Nothing to do if the rule is already in place.
        if armed { return }
        // Plug-in edge (or a retry after adbd wasn't ready yet): (re)establish
        // the reverse rule. A failure here just leaves us disarmed to retry on
        // the next tick.
        attemptArm()
    }

    /// Run `adb reverse` once; on success flip `armed` true. Assumes the caller
    /// already confirmed the device is present. Returns whether it stuck.
    @discardableResult
    private func attemptArm() -> Bool {
        guard let adb = Self.adbPath else { return false }
        let status = Self.run(adb, ["reverse", "tcp:\(Self.port)", "tcp:\(Self.port)"])
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
