import Foundation
import Darwin

/// Reads the kernel's VM counters on a timer and publishes one bool: is paging
/// costing CPU right now. See `MemoryPressurePolicy` for *why* these counters
/// and not the swap file.
///
/// Mechanically this is one `host_statistics64(HOST_VM_INFO64)` call per tick —
/// no subprocess, no `vm_stat` parsing, no entitlement. The counters it returns
/// are 64-bit and cumulative since boot, so a tick costs a struct copy and the
/// monitor is free to run for the life of the app.
final class MemoryPressureMonitor {

    private let queue = DispatchQueue(label: "ro.victorrentea.memory-pressure", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Guards everything the HTTP server and the main thread can read.
    private let lock = NSLock()
    private var _previous: MemoryPressurePolicy.Sample?
    private var _rates: MemoryPressurePolicy.Rates?
    private var _tracker = MemoryPressurePolicy.Tracker()
    private var _lastSampleAt: Date?
    private var _simulated: Bool?
    private var _simulatedUntil = Date.distantPast

    /// Fired on the **main thread**, and only when the answer changes.
    var onChange: ((Bool) -> Void)?

    /// How long a `/test/memory-pressure/simulate/<0|1>` override lasts. Long
    /// enough to walk over and look at the menu bar, short enough that a
    /// forgotten test override cannot leave the plate lying.
    static let simulationWindow: TimeInterval = 120

    var isHurting: Bool {
        lock.lock(); defer { lock.unlock() }
        if let simulated = _simulated, Date() < _simulatedUntil { return simulated }
        return _tracker.isHurting
    }

    func start(interval: TimeInterval = MemoryPressurePolicy.sampleInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A whole second of leeway on a 5 s timer: this is a diagnostic, and
        // waking the CPU on the dot to measure how busy the CPU is would be its
        // own small joke.
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Preview hook: force the plate on or off for `simulationWindow`, so the
    /// visual can be checked without filling 64 GB of RAM first.
    func simulate(hurting: Bool?) {
        let before = isHurting
        lock.lock()
        _simulated = hurting
        _simulatedUntil = hurting == nil ? .distantPast : Date().addingTimeInterval(Self.simulationWindow)
        lock.unlock()
        let after = isHurting
        if before != after {
            DispatchQueue.main.async { [weak self] in self?.onChange?(after) }
        }
    }

    /// Take one sample immediately, outside the timer — used by the test hook so
    /// a poll can be forced rather than waited for.
    func pollNow() { queue.sync { tick() } }

    // MARK: - Sampling

    private func tick() {
        guard let current = Self.readCounters() else { return }

        lock.lock()
        let previous = _previous
        _previous = current
        _lastSampleAt = current.at

        var flipped = false
        if let previous, let rates = MemoryPressurePolicy.Rates.between(previous, current) {
            _rates = rates
            flipped = _tracker.accept(MemoryPressurePolicy.verdict(for: rates))
        }
        let simulating = _simulated != nil && Date() < _simulatedUntil
        let state = _tracker.isHurting
        lock.unlock()

        // A live simulation owns the plate; a real flip underneath it is
        // recorded but not painted, or the override would be half-honoured.
        guard flipped, !simulating else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(state) }
    }

    /// One read of `HOST_VM_INFO64`. Nil only if the Mach call fails, which in
    /// practice means the host port is gone and the app has bigger problems.
    static func readCounters(now: Date = Date()) -> MemoryPressurePolicy.Sample? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryPressurePolicy.Sample(
            decompressions: UInt64(stats.decompressions),
            swapins: UInt64(stats.swapins),
            at: now)
    }

    /// The one-line "why" for the menu row under the flashing icon. Names the
    /// counter that actually crossed, because "memory pressure" alone sends you
    /// looking at the wrong column in Activity Monitor — the RAM bar can look
    /// calm while the compressor is the thing eating the core.
    var detailLine: String {
        lock.lock(); let rates = _rates; lock.unlock()
        guard let rates else { return "🟥 Paging is costing CPU" }
        if rates.swapinsPerSec >= MemoryPressurePolicy.swapinsWarn {
            return String(format: "🟥 Swapping in %.0f pages/s — RAM is full", rates.swapinsPerSec)
        }
        return String(format: "🟥 Compressor: %.0f decompressions/s", rates.decompressionsPerSec)
    }

    /// Snapshot for `/test/memory-pressure`, so the thresholds can be checked
    /// against live numbers from a script rather than from a screenshot.
    var diagnosticsJSON: String {
        lock.lock()
        let rates = _rates
        let tracker = _tracker
        let lastSampleAt = _lastSampleAt
        let simulating = _simulated != nil && Date() < _simulatedUntil
        let simulated = _simulated
        lock.unlock()

        let decomp = String(format: "%.1f", rates?.decompressionsPerSec ?? -1)
        let swapin = String(format: "%.1f", rates?.swapinsPerSec ?? -1)
        let age = lastSampleAt.map { Int(Date().timeIntervalSince($0).rounded()) } ?? -1
        return """
        {"hurting":\(isHurting),"measuredHurting":\(tracker.isHurting),\
        "decompressionsPerSec":\(decomp),"swapinsPerSec":\(swapin),\
        "streak":\(tracker.streak),"lastSampleAgeSec":\(age),\
        "simulating":\(simulating),"simulated":\(simulated.map(String.init) ?? "null"),\
        "warnAt":{"decompressionsPerSec":\(MemoryPressurePolicy.decompressionsWarn),\
        "swapinsPerSec":\(MemoryPressurePolicy.swapinsWarn)}}
        """
    }
}
