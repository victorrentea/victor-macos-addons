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
enum MemoryPressurePolicy {

    /// One reading of the kernel's VM counters. The counters are cumulative
    /// since boot; only differences between two samples mean anything.
    struct Sample: Equatable {
        let decompressions: UInt64
        let swapins: UInt64
        let at: Date
    }

    /// What the machine did between two samples, per second.
    struct Rates: Equatable {
        let decompressionsPerSec: Double
        let swapinsPerSec: Double

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
                swapinsPerSec: Double(current.swapins - previous.swapins) / seconds)
        }
    }

    /// How often the counters are read. Cheap — one `host_statistics64` call,
    /// no subprocess — so the interval is set by how fast the *plate* should
    /// react, not by cost.
    static let sampleInterval: TimeInterval = 5

    /// Above this the compressor is costing real CPU. Measured thrash sat at
    /// ~1000/s; an idle machine sits near zero and a cold app launch spikes for
    /// a second or two, which `sustainedSamples` eats.
    static let decompressionsWarn: Double = 400
    /// Hysteresis floor. Between `clear` and `warn` the plate keeps whatever
    /// state it already had, so a rate hovering around one number cannot make
    /// the menu bar strobe.
    static let decompressionsClear: Double = 150

    /// A page fetched from the swap file is one disk read plus a decrypt, an
    /// order of magnitude worse per page than a decompress — hence a threshold
    /// an order of magnitude lower.
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
        if rates.decompressionsPerSec >= decompressionsWarn || rates.swapinsPerSec >= swapinsWarn {
            return .hurting
        }
        if rates.decompressionsPerSec <= decompressionsClear && rates.swapinsPerSec <= swapinsClear {
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
