import Foundation

/// Whether 🛰️ **Claude RC in background** is armed — the row under 👩🏻‍💻 Extra.
///
/// **Default on**, and written out explicitly rather than left to
/// `UserDefaults.bool(forKey:)`, which answers `false` for a key nobody has ever
/// touched. The same reasoning as 🔄 Reverse Mouse Wheel next door: this is not
/// a nicety being offered, it takes over a behaviour that was *already* running
/// unconditionally (the `ro.victorrentea.claude-rc` LaunchAgent), so a fresh
/// launch has to reproduce the machine as it was — Remote Control up — or the
/// phone quietly stops being able to open sessions and nothing says why.
enum ClaudeRemoteControlSettings {
    static let enabledKey = "ClaudeRemoteControl.enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// What the watcher should do with the `claude-rc` tmux session on this tick.
enum ClaudeRemoteControlAction: Equatable {
    case leaveAlone
    case start
    case kill
}

/// The whole decision of 🛰️ Claude RC in background, lifted out of the timer and
/// the two `tmux` calls that drive it so it can be tested without a tmux server,
/// a Claude login or a minute of waiting.
///
/// It is a two-bit truth table and it is written down anyway, because the
/// asymmetry in it is the feature: **the tick is a one-way watchdog, not a
/// mirror.** Armed and dead → start it; disarmed and alive → kill it. The other
/// two cells do nothing, and in particular a *disarmed* tick does not keep
/// killing: the row means "I don't want the app minding this", so a session
/// Victor started by hand in a terminal afterwards must survive — killing it
/// every minute would make the unticked row more intrusive than the ticked one.
/// It is the toggle's own edge (`setEnabled(false)`) that kills once.
enum ClaudeRemoteControlPolicy {
    static func decide(enabled: Bool, sessionAlive: Bool) -> ClaudeRemoteControlAction {
        switch (enabled, sessionAlive) {
        case (true, false): return .start
        case (false, true): return .kill
        default: return .leaveAlone
        }
    }
}

/// 🛰️ Keeps `claude remote-control` — the persistent server the phone opens new
/// sessions against — alive in a detached tmux session, and gives it the off
/// switch it never had.
///
/// **Why it moved in here from launchd.** The behaviour itself is older: since
/// 14 Aug 2026 `~/Library/LaunchAgents/ro.victorrentea.claude-rc.plist` ran
/// `~/workspace/claude-rc.sh` at login plus a `StartInterval` re-check every 5
/// minutes. That watchdog had no way to be told *no*: killing the tmux session
/// bought at most five minutes of quiet before launchd put it back, so the only
/// real off switch was `launchctl bootout` — which is not a thing to reach for
/// mid-workshop. A menu row is, and a row that ticks is also the only place the
/// state is ever visible. **The LaunchAgent is booted out and `launchctl
/// disable`d**; two watchdogs racing over one tmux session would make the tick
/// a lie. This app is itself a LaunchAgent that is up from login, so nothing is
/// lost by the move — see docs/claude-remote-control.md.
///
/// **The script stays the source of truth for the flags.** `claude-rc.sh` holds
/// the distinction that cost a fortnight once — `claude remote-control` (the
/// *server*, 32 sessions, the phone can create new ones) versus
/// `claude --remote-control <name>` (the *flag*, one existing session exposed) —
/// plus the `--permission-mode auto` Victor asked for instead of a blanket
/// bypass, and the `ComputerName` prefix. Re-expressing that command in Swift
/// would be a second copy to drift; this launches the script it has always been.
///
/// **A real PTY is why tmux is still in the picture.** Remote Control needs one,
/// and neither launchd nor an `NSTask` gives it one, so the detached session is
/// not incidental — it is the only reason this works at all. It also means the
/// server survives the rebuild loop (`pkill` + `open`): a tmux server
/// double-forks away from whoever spawned it, so restarting this app does not
/// take Remote Control down with it. The arming tick is what covers the case
/// where it *was* already down.
final class ClaudeRemoteControl {

    /// Victor's number: "poll la 1 min ca ce pornit". Generous leeway on top —
    /// this is a watchdog, not a stopwatch, and letting the scheduler coalesce a
    /// once-a-minute `tmux has-session` is free.
    static let pollInterval: TimeInterval = 60

    static let sessionName = "claude-rc"

    private let queue = DispatchQueue(label: "ro.victorrentea.claude-rc-watch")
    private var timer: DispatchSourceTimer?
    /// Only for logging: the transitions are worth a line, sixty restatements an
    /// hour of "still up" are not.
    private var lastLoggedAlive: Bool?

    // MARK: - Lifecycle

    /// Called once at launch — and it is the *whole* answer to "after the app
    /// restarts I expect Remote Control back". The evaluation runs immediately
    /// rather than a minute from now, so a session that died while the app was
    /// being rebuilt is back up by the time the menu bar icon appears.
    func startIfEnabled() {
        setEnabled(ClaudeRemoteControlSettings.isEnabled, announce: false)
    }

    func setEnabled(_ enabled: Bool, announce: Bool = true) {
        ClaudeRemoteControlSettings.isEnabled = enabled
        guard enabled else {
            stopPolling()
            // The one place a kill happens. The tick never kills — see the policy.
            queue.async { [weak self] in
                guard let self else { return }
                if self.isSessionAlive() {
                    self.killSession()
                    if announce { overlayInfo("🛰️ Claude RC stopped — the phone can't open sessions until you tick it back") }
                } else if announce {
                    overlayInfo("🛰️ Claude RC was not running — nothing to stop")
                }
            }
            return
        }
        startPolling()
        queue.async { [weak self] in self?.evaluate(reason: "armed") }
        if announce { overlayInfo("🛰️ Claude RC armed — checked every \(Int(Self.pollInterval))s") }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pollInterval,
                   repeating: Self.pollInterval,
                   leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.evaluate(reason: "poll") }
        t.resume()
        timer = t
    }

    private func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - The tick

    private func evaluate(reason: String) {
        let alive = isSessionAlive()
        if lastLoggedAlive != alive {
            lastLoggedAlive = alive
            overlayInfo("🛰️ claude-rc \(alive ? "up" : "down") (\(reason))")
        }
        switch ClaudeRemoteControlPolicy.decide(enabled: ClaudeRemoteControlSettings.isEnabled,
                                                sessionAlive: alive) {
        case .leaveAlone:
            return
        case .kill:
            killSession()
        case .start:
            startSession(reason: reason)
        }
    }

    // MARK: - tmux

    /// `tmux` is looked up by path rather than trusted to `PATH`: under launchd
    /// this process has `/usr/bin:/bin:/usr/sbin:/sbin` and Homebrew is not in
    /// it, so a bare `tmux` would simply never be found — silently, once a
    /// minute, forever.
    static func tmuxPath() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func isSessionAlive() -> Bool {
        guard let tmux = Self.tmuxPath() else { return false }
        return run(tmux, ["has-session", "-t", Self.sessionName]) == 0
    }

    private func killSession() {
        guard let tmux = Self.tmuxPath() else { return }
        let status = run(tmux, ["kill-session", "-t", Self.sessionName])
        overlayInfo("🛰️ claude-rc killed (tmux exit \(status))")
        lastLoggedAlive = false
    }

    private func startSession(reason: String) {
        guard let script = Self.findScript() else {
            overlayError("🛰️ claude-rc.sh not found — Remote Control cannot be started")
            return
        }
        let status = run("/bin/zsh", [script])
        if status == 0 {
            overlayInfo("🛰️ claude-rc started (\(reason), \(script))")
            lastLoggedAlive = true
        } else {
            overlayError("🛰️ claude-rc.sh exited \(status) — Remote Control did not start")
        }
    }

    /// Resolve `claude-rc.sh` — same strategy as `BreakSummaryLauncher`, with
    /// the canonical `~/workspace` path first because that is where this script
    /// actually lives (it predates the app owning it, and the plist that used to
    /// run it points there).
    static func findScript() -> String? {
        let home = NSHomeDirectory()
        let envRoot = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"] ?? ""
        var candidates = ["\(home)/workspace/claude-rc.sh"]
        if !envRoot.isEmpty { candidates.append("\(envRoot)/claude-rc.sh") }
        candidates.append("\(FileManager.default.currentDirectoryPath)/claude-rc.sh")
        return candidates
            .map { URL(fileURLWithPath: $0).standardized.path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run and wait. Every call here is a millisecond of tmux bookkeeping —
    /// `has-session` asks the server a question, and `new-session -d` returns as
    /// soon as the detached session exists — so waiting keeps the state machine
    /// honest without ever blocking for long. It is on `queue`, never main.
    ///
    /// **`ANTHROPIC_API_KEY` is stripped from the child**, the Swift spelling of
    /// the `env -u ANTHROPIC_API_KEY` that fronts every other `claude` launcher
    /// in this app: the key in `~/.training-assistants-secrets.env` is out of
    /// credit, and exported it shadows the subscription and fails auth. Anything
    /// this process happens to have inherited must not reach the RC server.
    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            overlayError("🛰️ could not run \(path): \(error)")
            return -1
        }
    }

    // MARK: - Proof

    /// Backs `GET /test/claude-rc` — what the row claims, and what tmux says,
    /// side by side. The two disagreeing is the only failure this feature has.
    func stateJSON() -> String {
        let tmux = Self.tmuxPath().map { "\"\($0)\"" } ?? "null"
        let script = Self.findScript().map { "\"\($0)\"" } ?? "null"
        return "{\"enabled\":\(ClaudeRemoteControlSettings.isEnabled),"
            + "\"session\":\"\(Self.sessionName)\","
            + "\"alive\":\(isSessionAlive()),"
            + "\"watching\":\(timer != nil),"
            + "\"tmux\":\(tmux),"
            + "\"script\":\(script)}"
    }
}
