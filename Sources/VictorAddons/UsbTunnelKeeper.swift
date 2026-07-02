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
/// reverse rule can drop while we still believe we're armed — re-plugging the
/// cable or restarting the app re-arms it. Rare, and not worth a periodic `adb`
/// probe to cover.
final class UsbTunnelKeeper {
    private static let port = 55123
    private static let acInterval = 30       // seconds, on AC power
    private static let batteryInterval = 5   // seconds, on battery

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.usb-tunnel-keeper", qos: .utility)
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
        guard let adb = Self.adbPath else { return }
        let status = Self.run(adb, ["reverse", "tcp:\(Self.port)", "tcp:\(Self.port)"])
        if status == 0 { setArmed(true) }
    }

    private func setArmed(_ value: Bool) {
        guard armed != value else { return }
        armed = value
        NSLog(value
            ? "[UsbTunnelKeeper] USB tunnel armed — tablet reachable at localhost:\(Self.port)"
            : "[UsbTunnelKeeper] USB tunnel down — tablet unplugged")
    }

    /// True when an ADB-capable device is on USB, detected purely from the IO
    /// registry (no `adb` spawn). Matches the standard Android ADB interface:
    /// bInterfaceClass 255 (vendor-specific) / subclass 66 / protocol 1.
    private static func adbDevicePresent() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else {
            return false
        }
        // Property criteria must be nested under kIOPropertyMatchKey — top-level
        // keys are NOT applied by IOServiceGetMatchingServices (they silently
        // yield zero matches).
        matching[kIOPropertyMatchKey] = [
            "bInterfaceClass": 255,    // vendor-specific
            "bInterfaceSubClass": 66,  // ADB
            "bInterfaceProtocol": 1,
        ]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary, &iter) == KERN_SUCCESS else {
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
