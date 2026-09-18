import Foundation

/// Pure decisions behind 🟥 "the Mac is paging, and it is costing you CPU" —
/// the pulsing red plate the menu bar icon sits on while memory pressure is
/// actually stealing cycles.
///
/// **Why not `vm.swapusage`.** The obvious signal is the swap file, and it is
/// the wrong one twice over. Measured on this Mac on 2026-09-17, mid-thrash
/// (load average 274, `kernel_task` at 31%, 143 MB of 64 GB unused):
///
/// | counter | rate over a 30 s window |
/// |---|---|
/// | Swapouts | **0/s** |
/// | Swapins | ~1/s |
/// | **Decompressions** | **~1000/s** |
/// | Pageins | ~700/s |
///
/// `vm.swapusage` read 30.1 GB of 31.7 GB used and did not move the whole time.
/// A warning wired to it would have been on for days — permanently on is the
/// same as off, it just costs a red menu bar. A warning wired to swapins would
/// have stayed *dark* through the worst thrash this machine has had in weeks.
///
/// What actually hurts on Apple Silicon is the **compressor**: 25 GB of RAM held
/// compressed, and every touch of a compressed page is a synchronous decompress
/// on the CPU. That is the counter that moved, and it is the one that maps to
/// "hurting my CPU" — it *is* CPU, spent in the kernel, on nothing.
///
/// Swapins stay in the rule anyway, at a much lower threshold: a page that has
/// to come back from the encrypted swap file costs far more than one that comes
/// back from the compressor, so a hundredth of the rate is worth the same alarm.
///
/// **Why the compressor rate alone is not enough.** A busy-but-fine Mac lives
/// near the line: measured on 2026-09-18, 353 decompressions/s with 53% of the
/// CPU *idle* and nothing on the machine feeling slow. The compressor working is
/// not the complaint — the complaint is the compressor working while there are
/// no cycles left for anything else. So decompressions only light the plate when
/// the CPU is genuinely saturated at the same time; below that line the kernel
/// is decompressing in slack the machine had to spare, which is what slack is
/// for. Swapins keep their unconditional threshold: a page coming off the
/// encrypted swap file is a stall on disk, and a stall does not care how much
/// CPU is idle.
enum MemoryPressurePolicy {

    /// The host's cumulative CPU ticks, summed over all cores. Like the VM
    /// counters, only differences between two samples mean anything.
    struct CPUTicks: Equatable {
        /// user + system + nice.
        let busy: UInt64
        /// busy + idle.
        let total: UInt64

        /// The "counter did not move" reading. Deliberately scores as *fully
        /// busy* downstream, so a failed CPU read can never silence a real
        /// compressor alarm — see `Rates.between`.
        static let unknown = CPUTicks(busy: 0, total: 0)
    }

    /// One reading of the kernel's VM counters. The counters are cumulative
    /// since boot; only differences between two samples mean anything.
    struct Sample: Equatable {
        let decompressions: UInt64
        let swapins: UInt64
        let cpu: CPUTicks
        let at: Date
    }

    /// What the machine did between two samples, per second.
    struct Rates: Equatable {
        let decompressionsPerSec: Double
        let swapinsPerSec: Double
        /// Share of all CPU time that was not idle over the interval, 0…100.
        let cpuBusyPercent: Double

        /// Rates over the interval between `previous` and `current`.
        ///
        /// Returns nil rather than a wrong number for the two cases that are not
        /// a rate: a zero-or-negative interval (a clock that stepped), and a
        /// counter that went *down* (only happens across a reboot, and a reboot
        /// is precisely when the machine is not under pressure).
        static func between(_ previous: Sample, _ current: Sample) -> Rates? {
            let seconds = current.at.timeIntervalSince(previous.at)
            guard seconds > 0 else { return nil }
            guard current.decompressions >= previous.decompressions,
                  current.swapins >= previous.swapins else { return nil }
            return Rates(
                decompressionsPerSec: Double(current.decompressions - previous.decompressions) / seconds,
                swapinsPerSec: Double(current.swapins - previous.swapins) / seconds,
                cpuBusyPercent: cpuBusyPercent(from: previous.cpu, to: current.cpu))
        }

        /// Busy share between two tick readings. Over a 5 s window on ten cores
        /// the total moves by thousands of ticks, so a total that did *not*
        /// move means the read failed, not that the CPU stood still: that
        /// answers 100 and the gate stays open, leaving the old
        /// decompressions-only behaviour rather than a plate that quietly
        /// stopped working.
        private static func cpuBusyPercent(from previous: CPUTicks, to current: CPUTicks) -> Double {
            guard current.total > previous.total, current.busy >= previous.busy else { return 100 }
            let busy = Double(current.busy - previous.busy)
            let total = Double(current.total - previous.total)
            return min(100, busy / total * 100)
        }
    }

    /// How often the counters are read. Cheap — one `host_statistics64` call,
    /// no subprocess — so the interval is set by how fast the *plate* should
    /// react, not by cost.
    static let sampleInterval: TimeInterval = 5

    /// Above this the compressor is doing enough work to matter. Measured
    /// thrash sat at ~1000/s; an idle machine sits near zero and a cold app
    /// launch spikes for a second or two, which `sustainedSamples` eats. On its
    /// own it is not an alarm — `cpuBusyWarn` has to agree.
    static let decompressionsWarn: Double = 400
    /// Hysteresis floor. Between `clear` and `warn` the plate keeps whatever
    /// state it already had, so a rate hovering around one number cannot make
    /// the menu bar strobe.
    static let decompressionsClear: Double = 150

    /// The CPU half of the compressor rule: decompressing costs cycles, and
    /// spent cycles only hurt when there were none to spare. A machine at 80%
    /// busy has a fifth of a core's worth of headroom left across the box;
    /// below that the kernel is decompressing in slack.
    static let cpuBusyWarn: Double = 80
    /// Hysteresis floor for the same gate, so a load hovering at four fifths
    /// cannot strobe the plate either.
    static let cpuBusyClear: Double = 65

    /// A page fetched from the swap file is one disk read plus a decrypt, an
    /// order of magnitude worse per page than a decompress — hence a threshold
    /// an order of magnitude lower, and no CPU gate: this one is a stall, not a
    /// cycle cost, so an idle CPU is no consolation.
    static let swapinsWarn: Double = 50
    static let swapinsClear: Double = 10

    /// Consecutive qualifying samples before the plate changes state, in both
    /// directions. At a 5 s interval that is 15 s of sustained pressure to go
    /// red and 15 s of calm to go back — long enough that opening Xcode or
    /// waking a swapped-out Chrome does not flash the menu bar, short enough
    /// that it is still telling you about *now*.
    static let sustainedSamples = 3

    /// The verdict for one sample, before the sustain counting.
    enum Verdict: Equatable {
        /// Over the warn line — paging is costing CPU.
        case hurting
        /// Under the clear line — the machine is comfortable.
        case calm
        /// In the hysteresis band: says nothing, keeps whatever state is current.
        case unchanged
    }

    static func verdict(for rates: Rates) -> Verdict {
        if rates.swapinsPerSec >= swapinsWarn { return .hurting }
        if rates.decompressionsPerSec >= decompressionsWarn && rates.cpuBusyPercent >= cpuBusyWarn {
            return .hurting
        }
        // Either half of the compressor rule dropping out is enough to call the
        // machine comfortable: a busy CPU with a quiet compressor is just work
        // getting done, and a busy compressor with idle cores is not costing
        // anyone anything.
        if rates.swapinsPerSec <= swapinsClear
            && (rates.decompressionsPerSec <= decompressionsClear || rates.cpuBusyPercent <= cpuBusyClear) {
            return .calm
        }
        return .unchanged
    }

    /// The sustain counter. Kept as a value type so the whole state machine is
    /// testable without a timer, a Mac under load, or a `sleep` in a test.
    struct Tracker: Equatable {
        private(set) var isHurting = false
        /// Qualifying samples seen in a row *towards the state we are not in*.
        private(set) var streak = 0

        init(isHurting: Bool = false) {
            self.isHurting = isHurting
        }

        /// Feed one sample's verdict. Returns true when the state flipped, so
        /// the caller can repaint only on a change rather than every 5 s.
        @discardableResult
        mutating func accept(_ verdict: Verdict,
                             sustainedSamples: Int = MemoryPressurePolicy.sustainedSamples) -> Bool {
            let wants: Bool
            switch verdict {
            case .hurting: wants = true
            case .calm: wants = false
            // The band is not evidence for either side, and it must not *reset*
            // the streak either: a rate wobbling through the band on its way up
            // would otherwise never accumulate three samples and the plate would
            // never light. Neutral means neutral — the streak simply waits.
            case .unchanged: return false
            }

            guard wants != isHurting else {
                streak = 0
                return false
            }
            streak += 1
            guard streak >= sustainedSamples else { return false }
            isHurting = wants
            streak = 0
            return true
        }
    }
}
