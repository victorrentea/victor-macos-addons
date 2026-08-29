import Foundation

/// Finds the tablet over **WiFi** when it isn't on the cable, so the auto-deploy
/// (`AndroidAppDeployer`) gets its trigger either way.
///
/// `UsbTunnelKeeper` waits for an IOKit attach event, which is the right hook for
/// a cable and no hook at all for a tablet sitting on the far side of the room.
/// Since the tablet's wireless debugging is paired, adb can reach it with no
/// cable at all — but only after someone runs `adb connect`, and nobody was
/// running it. So the tablet would sit on an APK from three commits ago all
/// morning, current-looking, until the first tile press did the wrong thing.
///
/// **Which device it will connect to is the whole safety question.** `adb mdns
/// services` lists every Android on the network offering wireless debugging —
/// Victor's phone included — and connecting to the wrong one hands it to the
/// deployer, which is the exact failure `AndroidDeployPolicy.pickTablet` was
/// written for. So this never connects to a device it cannot already name: it
/// matches the mDNS service name against the tablet's **hardware serial**,
/// learned and persisted the last time the tablet was seen over any transport.
/// Before that first sighting it does nothing at all.
///
/// **The port is not stable.** Wireless debugging picks a fresh TLS port on every
/// toggle and every reboot, so the endpoint is rediscovered through mDNS each
/// time rather than remembered.
final class WirelessTabletLink {
    /// Same port the tablet's `MacLink` tries first. Reversed over the wireless
    /// transport exactly as over the cable, which is what keeps the tablet's
    /// sound routing on `localhost:55123` instead of falling back to LAN/relay.
    private static let port = 55123

    /// The tablet is normally reachable or normally absent for hours at a time,
    /// and each miss costs an `adb mdns services` spawn — so this polls far more
    /// slowly than the USB keeper, and slower still off AC.
    private static let acInterval = 60
    private static let batteryInterval = 300

    /// Where the tablet's hardware serial is remembered between launches. Learned
    /// from any transport (usually the cable), used only to recognise it later.
    private static let serialKey = "victor.tablet.hardwareSerial"

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.wireless-tablet", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Whether the tablet is currently reachable over adb. Lives only on `queue`.
    /// Edge-triggered, like `UsbTunnelKeeper.armed`, so a tablet that stays on
    /// the network all day fires the deploy once rather than every minute.
    private var reachable = false
    private var lastDiscoveryFailureLogged = false

    /// Fired on the edge where the tablet becomes reachable *and* the reverse
    /// tunnel is up. Wired to `AndroidAppDeployer.tabletConnected()`.
    var onTabletReachable: (() -> Void)?

    func start() {
        guard UsbTunnelKeeper.adbPath != nil else {
            NSLog("[WirelessTablet] adb not found — wireless deploy disabled")
            return
        }
        scheduleNext(after: 15)   // let the USB keeper's own first tick go first
    }

    /// The tablet's hardware serial, remembered from the last time it was seen.
    static var knownSerial: String? {
        let s = UserDefaults.standard.string(forKey: serialKey) ?? ""
        return s.isEmpty ? nil : s
    }

    /// Remember a tablet we are already talking to. Called from the deploy path,
    /// so the cable teaches this class who to look for on WiFi later.
    static func remember(hardwareSerial: String) {
        let s = hardwareSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != knownSerial else { return }
        UserDefaults.standard.set(s, forKey: serialKey)
        NSLog("[WirelessTablet] tablet hardware serial learned: \(s)")
    }

    // MARK: - Poll

    /// Self-rescheduling one-shot so the cadence can follow the power source
    /// between ticks, matching `UsbTunnelKeeper`'s pattern.
    private func scheduleNext(after seconds: Int) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(seconds))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick()
            self.scheduleNext(after: PowerMonitor.isOnAC() ? Self.acInterval : Self.batteryInterval)
        }
        t.resume()
        timer = t
    }

    private func tick() {
        // Already reachable — over the cable or over a wireless transport that is
        // still up. Nothing to discover; just hold the edge where it is. The USB
        // keeper owns the reverse tunnel in the cable case, and the connect path
        // below armed it in the wireless case.
        if case .tablet(let tablet) = AndroidAppDeployer.tabletSerial() {
            Self.remember(hardwareSerial: tablet.hardwareSerial)
            setReachable(true)
            return
        }
        setReachable(false)

        guard let serial = Self.knownSerial else { return }   // never met the tablet: nothing to look for
        guard let endpoint = Self.discover(hardwareSerial: serial) else { return }
        connect(to: endpoint)
    }

    /// Ask adb's mDNS browser for the tablet's wireless-debugging endpoint.
    /// Matches on the service name, which embeds the hardware serial
    /// (`adb-HVA5HP4L-b2mjKy  _adb-tls-connect._tcp  192.168.101.66:40633`) —
    /// that is what makes this safe to run on a room full of Android devices.
    private static func discover(hardwareSerial: String) -> String? {
        guard let adb = UsbTunnelKeeper.adbPath else { return nil }
        let out = run(adb, ["mdns", "services"], timeout: 20).output
        for line in out.split(separator: "\n") {
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3,
                  fields[0].hasPrefix("adb-\(hardwareSerial)-"),
                  fields[1].contains("_adb-tls-connect") else { continue }
            return fields[2]
        }
        return nil
    }

    /// `adb connect`, then the reverse tunnel, then the edge. Every step has to
    /// hold: a connect that succeeded but whose tunnel didn't arm would leave the
    /// tablet talking to the Mac over the LAN/relay path while we reported it
    /// reachable, which is exactly the silent half-working state the deploy
    /// notifications exist to prevent.
    private func connect(to endpoint: String) {
        guard let adb = UsbTunnelKeeper.adbPath else { return }
        let connect = Self.run(adb, ["connect", endpoint], timeout: 30)
        // `adb connect` exits 0 even when it failed, so the text is the verdict.
        guard connect.status == 0, connect.output.lowercased().contains("connected to") else {
            if !lastDiscoveryFailureLogged {
                lastDiscoveryFailureLogged = true
                NSLog("[WirelessTablet] adb connect \(endpoint) failed: \(connect.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return
        }
        lastDiscoveryFailureLogged = false

        // Re-ask through the normal picker rather than trusting the endpoint: it
        // re-reads `ro.build.characteristics` over the link that just came up, so
        // a serial that matched an old marker on a re-flashed device still can't
        // get the tablet's APK.
        guard case .tablet(let tablet) = AndroidAppDeployer.tabletSerial() else {
            NSLog("[WirelessTablet] connected to \(endpoint) but it doesn't look like the tablet — disconnecting")
            _ = Self.run(adb, ["disconnect", endpoint], timeout: 20)
            return
        }
        let reverse = Self.run(adb, ["-s", tablet.serial, "reverse", "tcp:\(Self.port)", "tcp:\(Self.port)"], timeout: 30)
        guard reverse.status == 0 else {
            NSLog("[WirelessTablet] connected to \(endpoint) but adb reverse failed — next tick will retry")
            return
        }
        NSLog("[WirelessTablet] tablet reachable over WiFi at \(endpoint) — tunnel armed on localhost:\(Self.port)")
        setReachable(true)
    }

    private func setReachable(_ value: Bool) {
        guard reachable != value else { return }
        reachable = value
        if value { onTabletReachable?() }
    }

    // MARK: - Process helper

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        // Read before waiting: a pipe that fills up deadlocks a process that is
        // still writing to it, and `adb mdns services` can be chatty.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
