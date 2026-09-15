import AppKit
import Foundation
import Network

/// Answers the second question 🔋 Claude prevents sleep has to ask: **how long
/// has this Mac been cut off from the internet?**
///
/// A Claude session with no link is not working, it is *waiting*. Since
/// 2026-09-14 Victor's `~/.claude/hooks/net-gate.sh` parks a turn the moment
/// `api.anthropic.com` stops answering and polls once a minute until it comes
/// back — deliberately, because Claude Code's internal retry ladder is a
/// hardcoded ~3 minutes and a turn that runs it out is killed. The park is the
/// right behaviour for the *session* and the worst possible behaviour for the
/// *lid*: a parked turn is still a live turn, so Claude Code keeps refreshing
/// its `caffeinate`, `ClaudeActivity` keeps reporting a working session, and a
/// laptop in a bag with no Wi-Fi holds itself awake all night to wait for a
/// network that is not coming back until it is taken out of the bag.
///
/// So the lid guard asks this too, and the rule Victor set is: **only activity
/// with internet keeps the Mac on**. Nothing else changes — with a link, the
/// feature behaves exactly as it always has.
///
/// **What it costs**: one TCP handshake every 30 s, and only while the lid
/// guard is armed. `LidAwake` starts and stops this alongside its own timer, so
/// a Mac with the row unticked pays nothing at all.
final class InternetWatch {

    /// **The host is the one that matters, not "the internet".** The failure
    /// this exists for is Claude Code being unable to reach its API, which is
    /// also what `net-probe.sh` tests, so a captive-portal Wi-Fi that carries
    /// LAN traffic but not Anthropic is offline for this purpose. A handshake
    /// to the real host proves DNS + TCP in one shot.
    static let probeHost = "api.anthropic.com"
    static let probePort: NWEndpoint.Port = 443

    /// **One failed probe is enough here, and that is not sloppiness.** The
    /// expensive false-positive that made `HotspotFallback` probe twice — a
    /// bogus "offline" costs a `networksetup` join that takes the Wi-Fi down —
    /// has no equivalent on this path: a missed handshake only leaves the clock
    /// running, and the very next probe 30 s later resets it. The five-minute
    /// grace *is* the confirmation, and it is a hundred times longer than any
    /// gap between two back-to-back probes could be.
    static let probeTimeout: TimeInterval = 4
    static let probeInterval: TimeInterval = 30

    /// The hooks' own evidence, reused rather than duplicated:
    /// `net-probe.sh` writes the epoch seconds of every **successful** probe
    /// here. A fresh stamp means a Claude reached the API a few seconds ago —
    /// the strongest proof of connectivity available on this Mac, and free.
    /// Only success is written, so a stale stamp proves nothing and we probe.
    static let hookStampPath = NSHomeDirectory() + "/.claude/net-probe"
    static let hookStampFreshness: TimeInterval = 45

    private let lock = NSLock()
    private var lastOnlineAt: Date?
    private var lastProbeAt = Date.distantPast
    private var pathSatisfied = true
    private var running = false
    /// Transition-only logging: while the lid guard is armed this refreshes
    /// twice a minute for hours, and a line per refresh would bury the log.
    private var lastVerdict: Bool?

    private var timer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.internet-watch", qos: .utility)
    /// The probe gets its own queue, for the reason `HotspotFallback` learned
    /// the hard way: the refresh blocks on `queue` waiting for the handshake, so
    /// running the connection's state handler there too deadlocks it and every
    /// probe reports offline — silently, and self-confirmingly.
    private let probeQueue = DispatchQueue(label: "ro.victorrentea.macos-addons.internet-watch.probe", qos: .utility)

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        let already = running
        running = true
        // The clock starts now. Arming into a dead network must buy the full
        // grace, not inherit however long the Mac happened to be offline before
        // anyone was watching.
        lastOnlineAt = Date()
        lastVerdict = nil
        lock.unlock()
        guard !already else { return }

        // `NWPathMonitor` cannot be restarted after `cancel()`, so it is built
        // per run rather than held for the life of the app.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.pathSatisfied = (path.status == .satisfied)
            self.lock.unlock()
            self.refresh(reason: "network change")
        }
        monitor.start(queue: queue)
        pathMonitor = monitor

        // Waking with the lid open in a new room must not be judged on the five
        // minutes of "offline" the Mac spent asleep: the clock is reset and the
        // question asked again from scratch.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.lastOnlineAt = Date()
            self.lock.unlock()
            self.refresh(reason: "wake")
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.probeInterval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.refresh(reason: "tick") }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        timer?.cancel()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - The answer

    /// Seconds since the internet was last proven reachable — **0 whenever we
    /// do not know**, which is the whole safety discipline of this file.
    ///
    /// Missing evidence is not evidence of an outage. The same reasoning as the
    /// unreadable battery in `LidAwakePolicy`: of the two possible mistakes,
    /// sleeping a Mac mid-flight because nobody was probing is much worse than
    /// holding it awake a while longer, so anything short of a measured outage
    /// reads as "online".
    func offlineFor(now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard running, let lastOnlineAt else { return 0 }
        return max(0, now.timeIntervalSince(lastOnlineAt))
    }

    // MARK: - Measuring

    private func refresh(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.running
            let satisfied = self.pathSatisfied
            let sinceProbe = Date().timeIntervalSince(self.lastProbeAt)
            self.lock.unlock()
            guard live else { return }

            // No route at all — the bag case, and the one where a handshake
            // would only burn four seconds to learn what the stack already
            // knows.
            guard satisfied else { return self.record(online: false, how: "no route (\(reason))") }

            if self.hookProbedRecently() { return self.record(online: true, how: "hook probe (\(reason))") }

            // A burst of path changes must not queue up a burst of handshakes.
            guard sinceProbe >= Self.probeInterval / 2 else { return }
            self.lock.lock(); self.lastProbeAt = Date(); self.lock.unlock()
            self.record(online: self.probe(), how: "probe (\(reason))")
        }
    }

    private func record(online: Bool, how: String) {
        lock.lock()
        if online { lastOnlineAt = Date() }
        let changed = (lastVerdict != online)
        lastVerdict = online
        let offline = lastOnlineAt.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()
        guard changed else { return }
        if online {
            overlayInfo("InternetWatch: online — \(how)")
        } else {
            overlayInfo("InternetWatch: no internet — \(how), offline for \(Int(offline))s")
        }
    }

    /// Did one of Victor's Claude hooks reach the API in the last few seconds?
    private func hookProbedRecently(now: Date = Date()) -> Bool {
        guard let raw = try? String(contentsOfFile: Self.hookStampPath, encoding: .utf8),
              let epoch = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let age = now.timeIntervalSince(Date(timeIntervalSince1970: epoch))
        return age >= 0 && age <= Self.hookStampFreshness
    }

    /// One TCP handshake. See `probeTimeout` for why one is enough here.
    private func probe() -> Bool {
        let conn = NWConnection(host: NWEndpoint.Host(Self.probeHost), port: Self.probePort, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; sem.signal()
            case .failed, .cancelled: ok = false; sem.signal()
            default: break
            }
        }
        conn.start(queue: probeQueue)
        _ = sem.wait(timeout: .now() + Self.probeTimeout)
        conn.cancel()
        return ok
    }
}
