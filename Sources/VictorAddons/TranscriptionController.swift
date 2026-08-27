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
    /// Fired when Whisper is alive but has stopped producing transcript: kill it
    /// and start it again. Main queue.
    var onForceRestart: (() -> Void)?

    private let isOnAC: () -> Bool
    private let isWhisperRunning: () -> Bool
    private let transcriptSilenceSeconds: () -> TimeInterval
    private var heartbeat: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.transcription-controller", qos: .utility)

    /// "Alive" was never the same as "working". A capture thread inside whisper
    /// can die on its own while the process, its other thread and its PID stay
    /// perfectly healthy — the icon says 💬, the heartbeat is satisfied, and not
    /// one word gets transcribed for hours. So the heartbeat also watches the
    /// *output*.
    static let silenceRestartThreshold: TimeInterval = 300  // 5 min without speech
    /// Never restart more often than this. If the room is simply quiet, or the
    /// mic is genuinely broken, a restart won't help and a loop would be worse
    /// than the silence.
    static let minRestartInterval: TimeInterval = 600
    private var lastForcedRestart: Date = .distantPast
    /// When whisper last came up, for the model-loading warm-up grace.
    private var runningSince: Date?

    init(isOnAC: @escaping () -> Bool = { PowerMonitor.isOnAC() },
         isWhisperRunning: @escaping () -> Bool,
         transcriptSilenceSeconds: @escaping () -> TimeInterval = { .infinity }) {
        self.isOnAC = isOnAC
        self.isWhisperRunning = isWhisperRunning
        self.transcriptSilenceSeconds = transcriptSilenceSeconds
    }

    /// Silence is `.infinity` when nothing has been transcribed at all today —
    /// which is the single most likely case when this fires. `Int(.infinity)`
    /// **traps**, so it must never reach a string interpolation: that crashed
    /// the whole app the first two times the watchdog triggered (2026-07-29,
    /// EXC_BREAKPOINT in heartbeatTick), and it crashed *before* restarting
    /// whisper, so it broke the very thing it was there to fix.
    static func describe(_ silence: TimeInterval) -> String {
        guard silence.isFinite else { return "nothing transcribed today" }
        return "\(Int(silence))s"
    }

    /// Pure decision: is a live-but-mute whisper due for a restart?
    ///
    /// `sinceStart` gates the model-loading window (a fresh whisper is silent for
    /// a minute or so by design) and `sinceLastRestart` gates the loop.
    static func shouldForceRestart(silence: TimeInterval,
                                   sinceStart: TimeInterval,
                                   sinceLastRestart: TimeInterval) -> Bool {
        silence > silenceRestartThreshold
            && sinceStart > silenceRestartThreshold
            && sinceLastRestart > minRestartInterval
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

    /// Re-launch Whisper so it picks up changed launch settings — but only if
    /// the power rule says it should be running at all.
    ///
    /// Callers used to do this themselves, with a bare `stop()` then `start()`.
    /// Two things went wrong and both are invisible until they bite. On
    /// **battery** that started Whisper and nothing ever stopped it again:
    /// `heartbeatTick` returns immediately off AC and `applyPowerState` only
    /// runs on a power *transition*, so a 1.8 GB model would sit there burning
    /// the battery until the next time the charger was plugged in — with the
    /// menu still reading "paused on battery". And skipping `noteStarted()`
    /// left the warm-up grace unset, so a quiet room could trip the
    /// output watchdog into force-restarting a process that had only just
    /// started loading its model.
    func restartIfShouldBeRunning(stop: @escaping () -> Void,
                                  start: @escaping () -> Void,
                                  delay: TimeInterval = 1.5) {
        guard isOnAC() else {
            // Off AC there is nothing to restart: the setting will be picked up
            // whenever the power rule next starts Whisper.
            if isWhisperRunning() { stop() }
            return
        }
        stop()
        noteStarted()
        // PortAudio needs a beat to release the devices before the replacement
        // grabs them, or the new process inherits the same mess.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { start() }
    }

    /// Sync Whisper to the current power source.
    private func applyPowerState() {
        let onAC = isOnAC()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPausedByBatteryChanged?(!onAC)
            if onAC {
                if !self.isWhisperRunning() { self.noteStarted(); self.onStart?() }
            } else {
                if self.isWhisperRunning() { self.runningSince = nil; self.onStop?() }
            }
        }
    }

    /// Heartbeat: while on AC, bring Whisper back if it died — and also if it is
    /// alive but has gone mute.
    private func heartbeatTick() {
        guard isOnAC() else { return }
        guard isWhisperRunning() else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isOnAC(), !self.isWhisperRunning() else { return }
                self.noteStarted()
                self.onStart?()
                self.onAutoRestart?()
            }
            return
        }

        let silence = transcriptSilenceSeconds()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOnAC(), self.isWhisperRunning() else { return }
            let now = Date()
            guard Self.shouldForceRestart(
                    silence: silence,
                    sinceStart: now.timeIntervalSince(self.runningSince ?? .distantPast),
                    sinceLastRestart: now.timeIntervalSince(self.lastForcedRestart))
            else { return }
            self.lastForcedRestart = now
            self.noteStarted()
            overlayError("Whisper alive but silent (\(Self.describe(silence))) — forcing a restart")
            self.onForceRestart?()
            self.onAutoRestart?()
        }
    }

    private func noteStarted() {
        runningSince = Date()
    }
}
