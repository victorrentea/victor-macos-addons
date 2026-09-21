import Darwin
import Foundation

/// One row of the process table, reduced to what the question needs.
struct RunningProcess: Equatable {
    let pid: Int32
    let ppid: Int32
    /// `p_comm` — the executable's name, truncated by the kernel to 16 chars.
    /// Both names this file cares about, `caffeinate` and `claude`, fit.
    let name: String
}

/// One row of `~/.claude/sessions/<pid>.json` — Claude Code's own presence
/// file — reduced to what the question needs.
///
/// The CLI writes one of these per live session and deletes it on exit.
///
/// **Its `status` field is better than this file first claimed**, and the
/// correction is worth writing down because the first reading was one sample.
/// Seeing a remote session at `busy` with `statusUpdatedAt` two seconds after
/// its own start looked like a field written once and abandoned; it was a
/// session that had simply been busy since it started. Re-measured across all
/// 13 live sessions later the same day, the falling edge is there too: a parked
/// remote session sat at `idle` with a `statusUpdatedAt` **twelve seconds
/// after** its last transcript line, 14 hours earlier.
///
/// It is not used *yet* — the transcript signal below was already shipped and
/// proven on the lid — but it is the more responsive of the two, and cheaper: a
/// state change is written the moment it happens, where the transcript has to
/// be read backwards and given a grace period. `sessionId` + `cwd` are what
/// locate the transcript.
struct SessionPresence: Equatable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    /// `cli` for a session in a terminal, `sdk-cli` for one the
    /// `claude remote-control` host drives.
    let entrypoint: String
    /// `busy` while a turn is running, then `idle` / `waiting` / `shell`.
    /// Empty when the field is missing, which is an older CLI.
    let status: String
    /// When `status` last changed — **not** when the file was last touched.
    let statusUpdatedAt: Date?
}

/// Answers one question for `LidAwake`: **is any Claude Code session actually
/// working right now?**
///
/// **The signal is Claude Code's own `caffeinate`.** A session spawns
/// `caffeinate -i -t 300` while it is doing something and lets it expire five
/// minutes later; it does not hold one while sitting idle at a prompt. Measured
/// on this Mac: 26 sessions open, **6** live `caffeinate` children — so the
/// process tracks activity, not existence. Every one of those six had a
/// `claude` parent.
///
/// That distinction is the whole feature. Victor keeps dozens of sessions open
/// all day; "a claude process exists" would mean the Mac never sleeps again,
/// which is the exact failure this is meant to prevent. "A claude is *working*"
/// is what holds the lid open.
///
/// **Parentage, not the argument string.** `-i -t 300` is today's invocation and
/// could change in any Claude Code release; a `caffeinate` whose parent is a
/// `claude` stays true regardless. It also excludes a `caffeinate` Victor
/// started by hand in a terminal, which should not hold the laptop awake for a
/// session that isn't there.
///
/// **The parent is identified by its executable path, not by its name.** This
/// cost a deploy: `p_comm`, the name in the process table, is the *filename* of
/// the binary — and Claude Code installs as
/// `~/.local/share/claude/versions/2.1.265`, so the kernel calls every session
/// `2.1.265`. (`ps -o comm=` prints `claude` only because that is `argv[0]`;
/// `ps -o ucomm=` shows the truth.) Matching `name == "claude"` therefore found
/// nothing while six sessions were working. `proc_pidpath` gives the real path
/// and the version in it stops mattering.
///
/// **The five-minute tail is a feature, not lag.** The last assertion outlives
/// the last piece of work by up to 300 s, so a session that pauses between
/// turns — waiting on an API round-trip, a long tool call — does not drop the
/// flag underneath itself. The Mac goes to sleep five minutes after the work
/// genuinely stops.
enum ClaudeActivity {

    static func isClaudeWorking() -> Bool { !workingSessions().isEmpty }

    /// The pids of the Claude Code sessions that are working right now.
    ///
    /// The Bool above is what the policy needs; this is what the *log* needs.
    /// "Everything has finished and the Mac is still awake" is unanswerable
    /// from a boolean — with the pids in the line, the holder is named and the
    /// question is over in one second. Naming them cost one debugging session
    /// on 2026-09-10, where the answer turned out to be the very Claude being
    /// asked to investigate.
    static func workingSessions() -> [Int32] {
        // A session can answer both signals at once, so the union is a set.
        Array(Set(interactiveWorkingSessions() + remoteWorkingSessions())).sorted()
    }

    /// The `caffeinate` half on its own — sessions someone is typing at.
    ///
    /// Split out from the union because the two halves are two menu rows since
    /// 2026-09-21: a Mac that must stay up for the phone is not the same
    /// promise as one that must stay up for the terminal, and Victor wanted to
    /// be able to give one of them away without the other.
    static func interactiveWorkingSessions() -> [Int32] {
        workingSessions(in: processTable(),
                        executablePath: executablePath(of:),
                        helperKind: helperKind(of:))
    }

    /// The decision, separated from the syscalls so it can be tested against a
    /// process table that is written down rather than whatever this Mac happens
    /// to be running.
    ///
    /// Only the parents of `caffeinate` processes are resolved to a path — a
    /// handful, never the whole table.
    static func isClaudeWorking(
        in procs: [RunningProcess],
        executablePath: (Int32) -> String?,
        helperKind: (Int32) -> String? = { _ in nil }
    ) -> Bool {
        !workingSessions(in: procs, executablePath: executablePath, helperKind: helperKind).isEmpty
    }

    static func workingSessions(
        in procs: [RunningProcess],
        executablePath: (Int32) -> String?,
        helperKind: (Int32) -> String? = { _ in nil }
    ) -> [Int32] {
        let parents = Set(procs.filter { $0.name == "caffeinate" }.map(\.ppid))
        return parents.filter { pid in
            guard let path = executablePath(pid), isClaudeExecutable(path: path) else { return false }
            // A daemon helper is the same binary as a session and is not one.
            return helperKind(pid) == nil
        }.sorted()
    }

    /// Which of Claude Code's own background helpers this pid is, or `nil` for
    /// a real session.
    ///
    /// **Measured 2026-09-10, and it is why the Mac would not sleep.** The
    /// daemon keeps pre-warmed processes around — `claude bg-spare --bg-spare
    /// /tmp/cc-daemon-501/…/claim.sock`, waiting to be handed to the next
    /// session, and the `bg-pty-host` behind it. They run the same binary from
    /// the same path as a session, and they spawn `caffeinate -i -t 300` of
    /// their own: pid 51845 held one, let it expire, and spawned another 30
    /// seconds later while nobody was working. Counted as sessions, they hold
    /// the lid open forever and the pulse never stops.
    ///
    /// **Told apart by `argv[1]`, not by a substring of the command line.** A
    /// session started as `claude -p "fix the bg-spare bug"` carries the words
    /// of its prompt in `argv`, and a match anywhere in that string would
    /// silently stop holding the lid open for the session most likely to be
    /// mid-flight. The marker is the *first argument*, which for a helper is
    /// the subcommand and for a session is a flag or nothing at all.
    ///
    /// Only helpers are excluded, never a claimed session: a spare that becomes
    /// a session drops the title (verified — this session's own `argv` is the
    /// versioned binary path and its flags, with no `bg-` anywhere).
    static func helperKind(of pid: Int32) -> String? {
        guard let argv1 = firstArgument(of: pid) else { return nil }
        return helperKind(firstArgument: argv1)
    }

    /// **The dashes are real and cost a first cut of this.** `ps` shows
    /// `claude bg-spare --bg-spare /tmp/…`, which reads as a subcommand — but
    /// `bg-spare` is part of `argv[0]`, the process *title*, and the actual
    /// `argv[1]` is `--bg-spare` (measured: `--bg-spare`, `--bg-pty-host`,
    /// against `--session-id` for a session). Matching the bare word found
    /// nothing at all, which is the silent kind of wrong: the exclusion would
    /// have shipped as a no-op and the spare would still be holding the lid.
    /// So the leading dashes come off before the comparison and both spellings
    /// are accepted.
    static func helperKind(firstArgument argv1: String) -> String? {
        let bare = String(argv1.drop(while: { $0 == "-" }))
        return helperSubcommands.contains(bare) ? bare : nil
    }

    static let helperSubcommands: Set<String> = ["bg-spare", "bg-pty-host", "bg-daemon"]

    /// `argv[1]` of a running process, via `sysctl(KERN_PROCARGS2)`.
    static func firstArgument(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseFirstArgument(procargs2: Array(buf.prefix(size)))
    }

    /// The parse, separated from the syscall so the layout is pinned by a test.
    ///
    /// `KERN_PROCARGS2` hands back `[argc: Int32][exec path\0][\0 padding]
    /// [argv[0]\0][argv[1]\0]…`, and the padding between the exec path and
    /// `argv[0]` is the part that trips a naive split: the strings have to be
    /// taken after *all* the run of NULs, not after the first one.
    static func parseFirstArgument(procargs2 buf: [UInt8]) -> String? {
        let intSize = MemoryLayout<Int32>.size
        guard buf.count > intSize else { return nil }
        let argc = buf.prefix(intSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 2 else { return nil }
        var i = intSize
        while i < buf.count, buf[i] != 0 { i += 1 }   // the exec path
        while i < buf.count, buf[i] == 0 { i += 1 }   // its padding
        var args: [String] = []
        var start = i
        while i < buf.count, args.count < 2 {
            if buf[i] == 0 {
                args.append(String(decoding: buf[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args.count >= 2 ? args[1] : nil
    }

    /// Is this binary a Claude Code CLI?
    ///
    /// Two shapes, and both are needed: the versioned install puts `claude` in
    /// the *directory* (`…/share/claude/versions/2.1.265`), a plain install
    /// puts it in the *filename* (`/opt/homebrew/bin/claude`).
    ///
    /// Deliberately not a substring test for "claude" anywhere in the path —
    /// `~/.local/bin/claude-gpt`, `claude-local`, `claude-docker` and friends
    /// are wrappers around other models and other machines, and none of them
    /// should hold this laptop's lid open.
    static func isClaudeExecutable(path: String) -> Bool {
        path.hasSuffix("/claude") || path.contains("/claude/")
    }

    /// The full path of a running binary, via `libproc`.
    static func executablePath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// `sysctl(KERN_PROC_ALL)` — the same source `pgrep` reads, rather than
    /// shelling out to `ps`. No process spawn on a path that runs every ten
    /// seconds for hours on a battery, and no dependence on `ps` being able to
    /// see the whole table (under a sandbox it cannot: measured at 31 rows of
    /// several hundred).
    static func processTable() -> [RunningProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between sizing it and reading it, so ask for
        // headroom rather than racing a short buffer into an ENOMEM.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        return procs.prefix(size / stride).map { p in
            // `p_comm` is a fixed-size C char tuple. Copying it to a local
            // first is not style: taking a pointer to the tuple inside the
            // closure while also reading `p` is an overlapping access the
            // compiler rejects.
            let comm = p.kp_proc.p_comm
            let name = withUnsafeBytes(of: comm) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            return RunningProcess(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, name: name)
        }
    }

    // MARK: - Sessions driven from the phone, which never spawn a `caffeinate`

    /// **Everything above reads the process table, and the process table cannot
    /// see a remote session working.** Measured 2026-09-21, and it is why this
    /// half exists:
    ///
    /// A session driven from the phone is not a terminal session. The
    /// `claude remote-control` host (in the `claude-rc` tmux) spawns one
    /// `claude --print --sdk-url https://api.anthropic.com/v1/code/sessions/…`
    /// per session, and **headless Claude Code never starts a
    /// `caffeinate`**: in the CLI bundle the sleep inhibitor has exactly one
    /// acquire site, an effect inside the terminal UI component
    /// (`if (status === "busy") acquire()`), and `--print` never renders it.
    /// Verified twice with a `claude -p` doing ~50 s of real work — zero new
    /// `caffeinate` — and on the live rig, where a remote session was writing
    /// its transcript that very minute while holding nothing.
    ///
    /// So with the row ticked and the lid shut, a turn started from the phone
    /// ran and the Mac went to sleep underneath it. That is the hole this
    /// closes.
    ///
    /// **The signal is the transcript's mtime.** Claude Code appends to
    /// `~/.claude/projects/<slug>/<sessionId>.jsonl` on every message — each
    /// assistant turn, each tool call, each result — and stops the moment the
    /// session parks at its prompt. Measured on the four live remote sessions:
    /// the two mid-work were 0 and 2.8 minutes old, the parked one 14 hours.
    /// That is the same shape as a `caffeinate`: it tracks work, not existence.
    ///
    /// **Only remote sessions get this rule**, deliberately. A terminal session
    /// already answers the sharper signal, and its `caffeinate` is released ~30 s
    /// after a turn ends — giving every idle terminal a five-minute tail instead
    /// would be a real regression for the two dozen Victor keeps open.
    ///
    /// **Known blind spot**: one tool call longer than `transcriptFreshness`
    /// with nothing written in between (a very long build) looks like silence,
    /// and the Mac is let go. Widen the window if it ever bites.
    static func remoteWorkingSessions() -> [Int32] {
        remoteWorkingSessions(
            in: sessionPresence(),
            transcript: { transcriptSignal(for: $0) },
            executablePath: executablePath(of:),
            now: Date())
    }

    /// When a session's transcript was last written, and what its last line
    /// says the session is doing.
    static func transcriptSignal(for session: SessionPresence) -> (modified: Date, state: TranscriptState)? {
        let url = transcriptPath(for: session)
        guard let modified = modificationDate(of: url) else { return nil }
        return (modified, transcriptState(tail: transcriptTail(at: url) ?? ""))
    }

    /// The decision, separated from the filesystem the same way the process
    /// half is separated from the syscalls.
    ///
    /// **The session's own `status` leads, and the transcript is the
    /// cross-check** (2026-09-21, second correction of the day). The field was
    /// dismissed in the morning on a single sample — a remote session at `busy`
    /// with `statusUpdatedAt` two seconds after its own start, which looked
    /// written-once and was simply a session that had been busy since it
    /// started. Re-measured over all 13 live sessions, it has both edges: the
    /// parked remote session sat at `idle`, stamped **twelve seconds after** its
    /// last transcript line, 14 hours earlier. It is written the moment the
    /// state changes, so it is the more responsive signal *and* the cheaper one.
    ///
    /// - `busy` — working, for as long as there is any **sign of life**: the
    ///   more recent of the status change and the last transcript write, capped
    ///   at `stallTimeout`. Measured live: two sessions busy for 145 and 125
    ///   minutes with transcripts 1 and 5 minutes old — genuinely inside long
    ///   tool calls, and held. A session blocked forever on something that never
    ///   answers goes quiet in both and is let go.
    /// - anything else (`idle`, `waiting`, `shell`) — finished. The transcript
    ///   is what guards the falling edge: a status that lags, or one left behind
    ///   by a restart, cannot sleep the Mac while lines are still being written.
    ///   `endTurnGrace` is 15 s now rather than 60, because the status flips at
    ///   the moment of the change instead of having to be inferred.
    /// - no status field at all — an older CLI. Falls back to the transcript
    ///   rule, unchanged.
    static func remoteWorkingSessions(
        in sessions: [SessionPresence],
        transcript: (SessionPresence) -> (modified: Date, state: TranscriptState)?,
        executablePath: (Int32) -> String?,
        now: Date
    ) -> [Int32] {
        sessions.filter { session in
            guard session.entrypoint == remoteEntrypoint else { return false }
            // The file outlives nothing, but a stale one outlives a crash — and
            // the same path test as above keeps a recycled pid from counting.
            guard let path = executablePath(session.pid), isClaudeExecutable(path: path) else { return false }
            let signal = transcript(session)
            let writeAge = signal.map { now.timeIntervalSince($0.modified) } ?? .greatestFiniteMagnitude
            switch session.status {
            case workingStatus:
                let statusAge = session.statusUpdatedAt.map { now.timeIntervalSince($0) }
                    ?? Double.greatestFiniteMagnitude
                return min(writeAge, statusAge) <= stallTimeout
            case "":
                guard let signal else { return false }
                switch signal.state {
                case .finished: return writeAge <= endTurnGrace
                case .working: return writeAge <= stallTimeout
                case .unknown: return writeAge <= transcriptFreshness
                }
            default:
                return writeAge <= endTurnGrace
            }
        }
        .map(\.pid)
        .sorted()
    }

    /// What the tail of a transcript says the session is doing.
    enum TranscriptState: Equatable {
        /// Inside a tool call, or thinking about the next one.
        case working
        /// The last turn ended — `stop_reason: "end_turn"` with nothing after it.
        case finished
        /// Nothing decisive in the tail. Falls back to the plain mtime rule.
        case unknown
    }

    /// Read the tail backwards to the first line that says something.
    ///
    /// **Sub-agent lines are skipped** (`isSidechain: true`): a subagent
    /// finishing with `end_turn` while its parent carries on would otherwise
    /// read as the whole session going idle, and on a shut lid that reads as
    /// "sleep now".
    ///
    /// `attachment` and `queue-operation` count as work: they are what a
    /// message queued from the phone looks like on its way in, and the `user`
    /// line only follows once the session picks it up.
    static func transcriptState(tail: String) -> TranscriptState {
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }   // also the half line the tail window cut in two
            if entry["isSidechain"] as? Bool == true { continue }
            switch entry["type"] as? String {
            case "assistant":
                let message = entry["message"] as? [String: Any]
                return (message?["stop_reason"] as? String) == "end_turn" ? .finished : .working
            case "user", "queue-operation", "attachment":
                return .working
            default:
                continue    // mode, ai-title, atis-latch, system, file-history-snapshot…
            }
        }
        return .unknown
    }

    /// The last slice of a file, without reading the rest of it: these
    /// transcripts reach 20 MB and this runs every ten seconds.
    static func transcriptTail(at url: URL, bytes: UInt64 = tailBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `entrypoint` a remote-control session writes. `cli` is a terminal.
    static let remoteEntrypoint = "sdk-cli"

    /// The fallback tail, for a transcript whose last lines say nothing either
    /// way: the same five minutes the `caffeinate` half has.
    static let transcriptFreshness: TimeInterval = 300

    /// How long a finished turn keeps the lid open. **Not zero**, because the
    /// gap between one turn ending and the next queued message being picked up
    /// is a second or two — and a tick landing in that gap with the lid shut
    /// would sleep the Mac in the middle of a conversation. Fifteen seconds
    /// since the status field took over: the end of a turn is now *stated*
    /// rather than inferred from the shape of the last line, so the grace only
    /// has to cover that gap, not the ambiguity.
    static let endTurnGrace: TimeInterval = 15

    /// The one `status` value that means a turn is running.
    static let workingStatus = "busy"

    /// How long a session that says it is mid-tool-call is believed. This is
    /// what carries a long build across the five-minute mark; the cap exists
    /// only so a session blocked forever on something that never answers (a
    /// permission prompt nobody taps) cannot hold the lid open all night.
    static let stallTimeout: TimeInterval = 900

    /// Enough tail to hold the last few lines of any transcript, and small
    /// enough to read six times a minute without noticing.
    static let tailBytes: UInt64 = 64 * 1024

    /// Every presence file Claude Code currently has on disk.
    ///
    /// Read fresh on every tick rather than watched: the whole directory is a
    /// dozen small files, and a `DispatchSource` per file would be more moving
    /// parts than the thing it watches.
    static func sessionPresence(dir: URL = sessionsDirectory) -> [SessionPresence] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String
            else { return nil }
            let changed = (json["statusUpdatedAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)   // the CLI writes milliseconds
            }
            return SessionPresence(pid: pid,
                                   sessionId: sessionId,
                                   cwd: cwd,
                                   entrypoint: json["entrypoint"] as? String ?? "",
                                   status: json["status"] as? String ?? "",
                                   statusUpdatedAt: changed)
        }
    }

    /// Where a session's transcript is, derived rather than searched: the 287
    /// project directories on this Mac are not worth walking six times a minute.
    ///
    /// A session that was resumed in a different directory than the one its
    /// presence file records therefore looks silent. Accepted: that is the
    /// behaviour of the day before this existed, not a new failure.
    static func transcriptPath(for session: SessionPresence, projects: URL = projectsDirectory) -> URL {
        projects
            .appendingPathComponent(projectSlug(cwd: session.cwd))
            .appendingPathComponent(session.sessionId + ".jsonl")
    }

    /// Claude Code's own encoding of a working directory into a folder name:
    /// everything outside `[A-Za-z0-9]` becomes a dash, leading slash included
    /// (`/Users/victorrentea/workspace` → `-Users-victorrentea-workspace`).
    /// Checked against all 14 live sessions on 2026-09-21.
    static func projectSlug(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var sessionsDirectory: URL { claudeHome.appendingPathComponent("sessions") }

    static var projectsDirectory: URL { claudeHome.appendingPathComponent("projects") }
}
