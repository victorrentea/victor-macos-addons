import Foundation
import Darwin

/// ✋ "Victor took control" — the pure half of interrupting the hands-off locks.
///
/// Victor, 2026-09-26: *"un mecanism prin care să pot întrerupe blocajul
/// ecranului: un click pe cele patru lăcățele din colțuri, și să comunice
/// agentului care ținea lacătele că am preluat controlul și să întrerupă ce
/// făcea."*
///
/// Until then the locks were a one-way contract: the agent says "don't touch",
/// Victor waits. When the agent is doing the wrong thing — or he simply needs
/// the machine back in the middle of a class — the only way out was to fight
/// the pointer, or find the right terminal and press Ctrl-C in it. Now a click
/// on any 🔒 (or ⌃⌘⎋ twice) is the stop button: the locks go red, the command
/// that holds them is killed, and the agent is *told*, in its own tool output.
///
/// Everything here is arithmetic and string composition; the AppKit and
/// `kill(2)` half lives in `HandsOffOverlay` / `HandsOffKiller`.

/// Who holds the locks, as far as the app can stop it. Registered by
/// `hands-off run` (`?holder=$$`, then `/hands-off/attach?child=$!`).
/// `hands-off start … ; … ; hands-off end` registers nothing: there is no
/// process to stop, only the locks to drop and the marker to write.
struct HandsOffHolder: Equatable {
    /// The `hands-off run` wrapper itself — told with SIGUSR1, so it can print
    /// the interruption line and exit 75.
    let holderPid: pid_t
    /// The process start time of the holder, taken when it registered. A pid on
    /// its own is not an identity: a wrapper that was SIGKILLed leaves its pid
    /// behind in a session that lives until the ttl, and by then the number may
    /// belong to something else entirely. The stamp is what makes "kill the
    /// holder" never mean "kill whoever got that number next".
    let holderStamp: ProcessStamp?
    /// The command the wrapper runs, in its own process group (`set -m`).
    var childPid: pid_t?
    var childStamp: ProcessStamp?
}

/// A pid plus its start time — the pair the kernel never reuses together.
struct ProcessStamp: Equatable {
    let pid: pid_t
    let startSec: UInt64
    let startUsec: UInt64

    /// Reads the live process' start time. nil = no such process (or not ours
    /// to inspect).
    static func of(_ pid: pid_t) -> ProcessStamp? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStamp(pid: pid, startSec: info.pbi_start_tvsec, startUsec: info.pbi_start_tvusec)
    }
}

/// Where a takeover came from — written to the log and the marker, so "why did
/// my command die" has an answer after the fact.
enum HandsOffTakeoverSource: String {
    case click       // a real click on one of the 🔒
    case keyboard    // ⌃⌘⎋ twice within a second
    case test        // GET /test/hands-off/takeover
}

/// The one state machine: idle → taking over (red ✋ for ~2 s) → idle.
/// A second click during the red state is the same takeover, not another one —
/// Victor clicking three locks in a row out of urgency must not write three
/// markers or signal a pid that has already been told.
struct HandsOffTakeoverMachine: Equatable {
    enum Phase: Equatable {
        case idle
        case takingOver(since: Date)
    }

    private(set) var phase: Phase = .idle

    /// How long the red ✋ state stays up before the panels fade. Long enough to
    /// be read from across the desk, short enough that he is not waiting on it.
    static let redStateDuration: TimeInterval = 2.0

    var isTakingOver: Bool {
        if case .takingOver = phase { return true }
        return false
    }

    /// A takeover request. True = do it now; false = nothing to take (no locks
    /// up) or one is already running.
    mutating func request(locksUp: Bool, at now: Date) -> Bool {
        if case .takingOver(let since) = phase {
            // Stuck-state guard: if `finish` was somehow never called, a later
            // request after the red state is over is a fresh one.
            guard now.timeIntervalSince(since) >= Self.redStateDuration else { return false }
            phase = .idle
        }
        guard locksUp else { return false }
        phase = .takingOver(since: now)
        return true
    }

    mutating func finish() { phase = .idle }
}

/// ⌃⌘⎋ **twice within a second**. Once is not enough on purpose: the chord is
/// swallowed while the locks are up, and a single stray press must not kill an
/// agent's work. Twice is deliberate, and still possible with a pointer being
/// dragged around by someone else.
struct HandsOffDoublePress: Equatable {
    static let window: TimeInterval = 1.0
    private var lastPress: Date?

    /// True on the press that completes the pair (and resets, so a third press
    /// starts a new pair rather than firing again).
    mutating func press(at now: Date) -> Bool {
        if let last = lastPress, now.timeIntervalSince(last) <= Self.window, now >= last {
            lastPress = nil
            return true
        }
        lastPress = now
        return false
    }
}

/// What to signal. Decided purely from pids and groups so the safety rules —
/// never our own group, never the agent's shell — are tested, not hoped for.
struct HandsOffKillPlan: Equatable {
    enum Target: Equatable {
        /// `kill(-pgid, …)`: the child and everything it spawned.
        case group(pid_t)
        /// Just that pid: used when the child did NOT get its own group, because
        /// then its group is the wrapper's — and the wrapper's is usually the
        /// agent's own shell, which we must not take down with it.
        case process(pid_t)
    }

    /// SIGUSR1 goes here first: the wrapper, so it knows *why* its child died.
    let notify: pid_t?
    /// SIGTERM now, SIGKILL 3 s later to whatever is still alive.
    let terminate: [Target]

    static let killGrace: TimeInterval = 3.0

    static let empty = HandsOffKillPlan(notify: nil, terminate: [])

    /// - Parameters:
    ///   - holder: what `hands-off run` registered, already checked for liveness
    ///     and identity (a stale stamp means pass nil here).
    ///   - childPgid / holderPgid: `getpgid` of each, nil if unknown.
    ///   - ownPid / ownPgid: this app — never a target.
    static func make(holder: HandsOffHolder?, childPgid: pid_t?, holderPgid: pid_t?,
                     ownPid: pid_t, ownPgid: pid_t) -> HandsOffKillPlan {
        guard let holder else { return .empty }
        let holderPid = holder.holderPid
        let notify: pid_t? = (holderPid > 1 && holderPid != ownPid) ? holderPid : nil

        var targets: [Target] = []
        if let child = holder.childPid, child > 1, child != ownPid, child != holderPid {
            if let pgid = childPgid, pgid == child, pgid != ownPgid, pgid != holderPgid {
                targets.append(.group(pgid))
            } else {
                targets.append(.process(child))
            }
        }
        return HandsOffKillPlan(notify: notify, terminate: targets)
    }
}

/// `~/.victor-addons/hands-off.takeover` — the note left for whoever held the
/// locks. `hands-off run` refuses to start for 60 s after it is written (unless
/// `--after-takeover`), so an agent cannot grab the screen straight back; it has
/// to read the message first. `hands-off start/end` users must poll it.
enum HandsOffTakeoverMarker {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".victor-addons", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("hands-off.takeover") }

    /// The wall-clock time in the interruption line — `HH:mm:ss`, local.
    static func localTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// One JSON object; the wrapper reads `holderPid` (was it me?) and `atLocal`
    /// (for the message). Keys are sorted so the file is diffable and testable.
    static func json(at date: Date, source: HandsOffTakeoverSource, label: String?, agent: String?,
                     holder: HandsOffHolder?) -> String {
        var obj: [String: Any] = [
            "at": Int(date.timeIntervalSince1970),
            "atLocal": localTime(date),
            "source": source.rawValue,
            "message": "Victor took control at \(localTime(date)) — stop what you were doing",
        ]
        if let label { obj["why"] = label }
        if let agent { obj["agent"] = agent }
        if let holder {
            obj["holderPid"] = Int(holder.holderPid)
            if let c = holder.childPid { obj["childPid"] = Int(c) }
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func write(_ json: String, to target: URL = url) -> Bool {
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (json + "\n").write(to: target, atomically: true, encoding: .utf8)
            return true
        } catch {
            overlayError("Hands off: could not write takeover marker: \(error)")
            return false
        }
    }
}

/// The `kill(2)` half. Not on the main actor: the SIGKILL follow-up runs on a
/// background queue three seconds later.
enum HandsOffKiller {
    /// Liveness + identity: the process with this pid is still the one that
    /// registered. A missing stamp at registration means "trust the pid" — the
    /// app could not read it then (it always can for our own user's processes).
    static func isSame(pid: pid_t, stamp: ProcessStamp?) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let stamp else { return true }
        return ProcessStamp.of(pid) == stamp
    }

    /// Executes the plan. Returns a one-line description for the log.
    @discardableResult
    static func execute(_ plan: HandsOffKillPlan) -> String {
        var parts: [String] = []
        if let pid = plan.notify {
            let rc = kill(pid, SIGUSR1)
            parts.append("USR1→\(pid)\(rc == 0 ? "" : " (failed)")")
        }
        for target in plan.terminate {
            let rc = send(SIGTERM, to: target)
            parts.append("TERM→\(describe(target))\(rc == 0 ? "" : " (failed)")")
        }
        if !plan.terminate.isEmpty {
            let targets = plan.terminate
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + HandsOffKillPlan.killGrace) {
                for target in targets where isAlive(target) {
                    _ = send(SIGKILL, to: target)
                    overlayInfo("Hands off: \(describe(target)) ignored SIGTERM for \(Int(HandsOffKillPlan.killGrace))s — SIGKILL")
                }
            }
        }
        return parts.isEmpty ? "nothing to signal" : parts.joined(separator: ", ")
    }

    private static func send(_ sig: Int32, to target: HandsOffKillPlan.Target) -> Int32 {
        switch target {
        case .group(let pgid): return kill(-pgid, sig)
        case .process(let pid): return kill(pid, sig)
        }
    }

    private static func isAlive(_ target: HandsOffKillPlan.Target) -> Bool {
        switch target {
        case .group(let pgid): return kill(-pgid, 0) == 0
        case .process(let pid): return kill(pid, 0) == 0
        }
    }

    static func describe(_ target: HandsOffKillPlan.Target) -> String {
        switch target {
        case .group(let pgid): return "group \(pgid)"
        case .process(let pid): return "pid \(pid)"
        }
    }
}

/// The one bit the event-tap thread needs: are the locks up right now? Set on
/// main by the overlay, read off-main by `EventTapManager` to decide whether
/// ⌃⌘⎋ is ours to swallow.
final class HandsOffGate: @unchecked Sendable {
    static let shared = HandsOffGate()
    private let lock = NSLock()
    private var up = false

    var locksUp: Bool {
        get { lock.lock(); defer { lock.unlock() }; return up }
        set { lock.lock(); up = newValue; lock.unlock() }
    }
}
