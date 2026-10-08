import Cocoa

/// ✈️ Once an hour, asks Gmail whether an airline wrote "check-in is open"
/// (`CheckInMailPolicy.query`), and for each new one: marks it read and raises
/// the `CheckInAlarm` pill.
///
/// **Through `gmail-cli`, not the Gmail MCP connector.** The connector lives
/// inside a Claude session; reaching it from here would mean a `claude -p` run
/// every hour, 24 a day, spending subscription quota to run one fixed search.
/// `gmail-cli` (the `gmail-web` skill, `~/.local/bin/gmail-cli`) drives a
/// headless Chrome on its own signed-in profile: ~10 s, no model, nothing
/// visible. Its `search` lists results **without opening them**, so looking
/// does not mark anything read; `read` is the step that does, on purpose, and
/// only for hits that are new *and* still unread.
///
/// **Marked read because the pill replaces the mail as the reminder.** Unread
/// mail is Victor's TODO queue (`gmail-cli`'s own comment) — an airline nudge
/// sitting there next to real work is noise once the pill has it.
///
/// Ticks every 5 min and polls when the last poll is an hour old, so a Mac that
/// slept through the hour checks soon after it wakes. A failed poll (no network,
/// Gmail signed out, the shared headless profile busy with another `gmail-cli`)
/// is logged and retried on the next hour; nothing is marked seen.
final class CheckInMailWatch {
    static let interval: TimeInterval = 3600
    private static let tick: TimeInterval = 300
    private static let timeout: TimeInterval = 180
    private static let seenKey = "checkin.seen"
    private static let seenCap = 300

    private let alarm: CheckInAlarm
    private let queue = DispatchQueue(label: "checkin-mail-watch", qos: .utility)
    private var timer: Timer?
    private var lastCheck: Date?
    private var running = false
    private var lastResult = "never polled"

    private let cli = NSHomeDirectory() + "/.local/bin/gmail-cli"

    init(alarm: CheckInAlarm) { self.alarm = alarm }

    func start() {
        // First look a minute after launch: not in the middle of the start-up rush,
        // and soon enough that a restart doesn't cost an hour of watching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.maybePoll() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            self?.maybePoll()
        }
    }

    private func maybePoll() {
        guard CheckInMailPolicy.isDue(lastCheck: lastCheck, now: Date(), every: Self.interval) else { return }
        pollNow()
    }

    /// `GET /test/checkin/poll` — check now, whatever the clock says.
    func pollNow() {
        guard !running else { return }
        running = true
        lastCheck = Date()
        queue.async { [weak self] in self?.poll() }
    }

    private var seen: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
    }

    private func remember(_ ids: [String]) {
        var list = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
        list.append(contentsOf: ids)
        if list.count > Self.seenCap { list.removeFirst(list.count - Self.seenCap) }
        UserDefaults.standard.set(list, forKey: Self.seenKey)
    }

    private func poll() {
        defer { DispatchQueue.main.async { [weak self] in self?.running = false } }
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            finish("gmail-cli missing at \(cli)", error: true)
            return
        }
        let (status, out, err) = run([cli, "search", CheckInMailPolicy.query, "20", "--json"])
        guard status == 0, let hits = CheckInMailPolicy.decode(out) else {
            finish("search failed (exit \(status)): \(Self.tail(err))", error: true)
            return
        }
        let fresh = CheckInMailPolicy.fresh(hits, seen: seen)
        guard !fresh.isEmpty else {
            finish("\(hits.count) check-in mail(s) in the last day, none new", error: false)
            return
        }
        // Mark read before ringing: if this fails the pill still shows, and the
        // mail stays unread — the worse outcome would be the other way round.
        let unread = fresh.filter(\.unread).count
        if unread > 0 {
            let (rs, _, rerr) = run([cli, "read", CheckInMailPolicy.unreadQuery, String(unread), "--json"])
            if rs != 0 { overlayError("✈️ couldn't mark the check-in mail read (exit \(rs)): \(Self.tail(rerr))") }
        }
        remember(fresh.map(\.threadId))
        finish("\(fresh.count) new: " + fresh.map(\.subject).joined(separator: " · "), error: false)
        DispatchQueue.main.async { [weak self] in self?.alarm.raise(fresh) }
    }

    private func finish(_ message: String, error: Bool) {
        lastResult = "\(Self.stamp()) \(message)"
        if error { overlayError("✈️ check-in watch: \(message)") }
        else { overlayInfo("✈️ check-in watch: \(message)") }
    }

    /// Run a command with a PATH that finds `node` and `playwright-cli` (the
    /// LaunchAgent starts this app with launchd's bare PATH), killed after
    /// `timeout` so a wedged headless Chrome can't hold the watch forever.
    private func run(_ argv: [String]) -> (Int32, Data, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, Data(), "\(error)") }
        // Drain both pipes while it runs: a full pipe buffer would block the child.
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        return (p.terminationStatus, out, String(data: err, encoding: .utf8) ?? "")
    }

    private static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n").suffix(3)
        return lines.joined(separator: " | ")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// `GET /test/checkin` — the last poll's outcome plus what the pill holds.
    var diagnosticsJSON: String {
        let last = lastCheck.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        return "{\"last_check\":\(last),\"running\":\(running),\"last_result\":\(CheckInAlarm.quote(lastResult)),\"alarm\":\(alarm.stateJSON())}"
    }
}
