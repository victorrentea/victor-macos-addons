import Foundation

/// Dead-simple transcription lifecycle.
///
/// The rule is: **Whisper runs whenever the Mac is on AC power, and is paused
/// on battery.** There is no schedule, no workday window, and no manual
/// start/stop — transcription is always on while plugged in. A 60s heartbeat
/// restarts Whisper if it died (crash, OOM) while still on AC, so the "100% of
/// the time on AC" guarantee survives an unexpected exit.
///
/// This replaces the former TranscriptionStateMachine (off/on/onWorkday/battery)
/// + TranscriptionScheduler (Mon–Fri 09:00–18:00) pair: the only input that
/// matters now is the power source.
final class TranscriptionController {
    /// Start Whisper. Always invoked on the main queue.
    var onStart: (() -> Void)?
    /// Stop Whisper. Always invoked on the main queue.
    var onStop: (() -> Void)?
    /// Reports the high-level UI status: `true` = paused because on battery.
    /// Always invoked on the main queue.
    var onPausedByBatteryChanged: ((Bool) -> Void)?
    /// Fired when the heartbeat brings Whisper back after an unexpected death
    /// (distinct from a deliberate power-on start). Main queue.
    var onAutoRestart: (() -> Void)?

    private let isOnAC: () -> Bool
    private let isWhisperRunning: () -> Bool
    private var heartbeat: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.transcription-controller", qos: .utility)

    init(isOnAC: @escaping () -> Bool = { PowerMonitor.isOnAC() },
         isWhisperRunning: @escaping () -> Bool) {
        self.isOnAC = isOnAC
        self.isWhisperRunning = isWhisperRunning
    }

    /// Call once on launch: applies the current power state and arms the
    /// heartbeat.
    func start() {
        applyPowerState()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in self?.heartbeatTick() }
        t.resume()
        heartbeat = t
    }

    /// Call from PowerMonitor's AC/battery callbacks.
    func powerDidChange() {
        applyPowerState()
    }

    /// Sync Whisper to the current power source.
    private func applyPowerState() {
        let onAC = isOnAC()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPausedByBatteryChanged?(!onAC)
            if onAC {
                if !self.isWhisperRunning() { self.onStart?() }
            } else {
                if self.isWhisperRunning() { self.onStop?() }
            }
        }
    }

    /// Crash recovery: while on AC, bring Whisper back if it died.
    private func heartbeatTick() {
        guard isOnAC(), !isWhisperRunning() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOnAC(), !self.isWhisperRunning() else { return }
            self.onStart?()
            self.onAutoRestart?()
        }
    }
}
