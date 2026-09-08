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
/// **The five-minute tail is a feature, not lag.** The last assertion outlives
/// the last piece of work by up to 300 s, so a session that pauses between
/// turns — waiting on an API round-trip, a long tool call — does not drop the
/// flag underneath itself. The Mac goes to sleep five minutes after the work
/// genuinely stops.
enum ClaudeActivity {

    static func isClaudeWorking() -> Bool {
        isClaudeWorking(in: processTable())
    }

    /// The decision, separated from the syscall so it can be tested against a
    /// process table that is written down rather than whatever this Mac happens
    /// to be running.
    static func isClaudeWorking(in procs: [RunningProcess]) -> Bool {
        var nameByPid: [Int32: String] = [:]
        nameByPid.reserveCapacity(procs.count)
        for p in procs { nameByPid[p.pid] = p.name }

        return procs.contains { p in
            p.name == "caffeinate" && nameByPid[p.ppid] == "claude"
        }
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
}
