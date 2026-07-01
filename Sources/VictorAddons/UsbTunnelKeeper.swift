import Foundation

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
/// `start.sh` runs `adb reverse` once at app launch, which only helps if the
/// tablet happens to be plugged in at that exact moment. This re-runs it on a
/// short timer — idempotent, and a harmless no-op when no device is connected —
/// so plugging the cable in mid-session restores the backup within ~20s,
/// hands-off. Logs only on armed↔down transitions (no per-tick spam).
final class UsbTunnelKeeper {
    private static let port = 55123
    private static let pollInterval = 20  // seconds

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.usb-tunnel-keeper", qos: .utility)
    /// Last observed armed state — logged only when it flips. Lives only on
    /// `queue`, so reads/writes are sequential.
    private var lastArmed: Bool?

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
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: .seconds(Self.pollInterval))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let adb = Self.adbPath else { return }
        // Already armed? `adb reverse --list` prints "... tcp:55123 tcp:55123".
        // Cheap steady-state check that avoids re-registering the rule each tick.
        let list = Self.run(adb, ["reverse", "--list"])
        if list.status == 0 && list.output.contains("tcp:\(Self.port)") {
            report(armed: true)
            return
        }
        // Rule missing, or no device attached. Try to (re)establish it — a
        // harmless failure when no tablet is on USB.
        let res = Self.run(adb, ["reverse", "tcp:\(Self.port)", "tcp:\(Self.port)"])
        report(armed: res.status == 0)
    }

    private func report(armed: Bool) {
        guard lastArmed != armed else { return }
        lastArmed = armed
        NSLog(armed
            ? "[UsbTunnelKeeper] USB tunnel armed — tablet reachable at localhost:\(Self.port)"
            : "[UsbTunnelKeeper] USB tunnel down — no tablet on USB")
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }
}
