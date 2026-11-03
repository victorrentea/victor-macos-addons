import Foundation

/// Dead-simple transcription lifecycle.
///
/// The rule is: **on AC, Whisper transcribes; on battery, it only records**
/// (since 2026-11-03 — before that it stopped outright, and an important meeting
/// taken on battery left no trace at all). In `.captureOnly` the microphones stay
/// open and each channel goes to `battery-audio/` without the 1.8 GB model ever
/// being loaded; the full process that starts on AC transcribes that audio and
/// slots it into the day's transcript at the minute it was spoken
/// (`whisper-transcribe/battery_audio.py`).
///
/// The battery recording can be switched off from the menu. That choice lasts
/// until the charger is next plugged in — the next unplugging records again.
///
/// A 60s heartbeat restarts Whisper, in whichever mode the power source asks
/// for, if it died (crash, OOM, the capture-stall watchdog's exit).
///
/// There is deliberately no rule here based on the transcript going quiet —
/// silence cannot tell a dead microphone from an empty room, and it used to
/// restart Whisper every 10 minutes all night.
final class TranscriptionController {
    enum Mode: Equatable {
        /// On AC: live transcription (and the battery backlog, if any).
        case full
        /// On battery: record only, no model.
        case captureOnly
    }

    enum State: Equatable {
        case onAC
        case recordingOnBattery
        /// On battery with the recording switched off from the menu.
        case pausedOnBattery
    }

    /// Start Whisper in `Mode`. Always invoked on the main queue.
    var onStart: ((Mode) -> Void)?
    /// Stop Whisper. Always invoked on the main queue.
    var onStop: (() -> Void)?
    /// Reports the high-level state on every change. Main queue.
    var onStateChanged: ((State) -> Void)?
    /// Fired when the heartbeat brings Whisper back after an unexpected death
    /// (distinct from a deliberate power-on start). Main queue.
    var onAutoRestart: ((Mode) -> Void)?

    private let isOnAC: () -> Bool
    private let isWhisperRunning: () -> Bool
    private let switchDelay: TimeInterval
    private var heartbeat: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "ro.victorrentea.macos-addons.transcription-controller", qos: .utility)

    /// Main-queue state.
    private(set) var runningMode: Mode?
    /// The menu's "stop recording on battery". Reset by the charger.
    private(set) var batteryRecordingEnabled = true
    private var lastReportedState: State?

    init(isOnAC: @escaping () -> Bool = { PowerMonitor.isOnAC() },
         isWhisperRunning: @escaping () -> Bool,
         switchDelay: TimeInterval = 1.5) {
        self.isOnAC = isOnAC
        self.isWhisperRunning = isWhisperRunning
        self.switchDelay = switchDelay
    }

    /// What should be running right now, if anything.
    static func desiredMode(onAC: Bool, batteryRecordingEnabled: Bool) -> Mode? {
        if onAC { return .full }
        return batteryRecordingEnabled ? .captureOnly : nil
    }

    static func state(onAC: Bool, batteryRecordingEnabled: Bool) -> State {
        if onAC { return .onAC }
        return batteryRecordingEnabled ? .recordingOnBattery : .pausedOnBattery
    }

    var desiredMode: Mode? {
        Self.desiredMode(onAC: isOnAC(), batteryRecordingEnabled: batteryRecordingEnabled)
    }

    var state: State {
        Self.state(onAC: isOnAC(), batteryRecordingEnabled: batteryRecordingEnabled)
    }

    /// Call once on launch: applies the current power state and arms the
    /// heartbeat.
    func start() {
        DispatchQueue.main.async { [weak self] in self?.apply() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.heartbeatTick() }
        }
        t.resume()
        heartbeat = t
    }

    /// Call from PowerMonitor's AC/battery callbacks.
    func powerDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Plugging in resets the menu's "stop recording on battery".
            if self.isOnAC() { self.batteryRecordingEnabled = true }
            self.apply()
        }
    }

    /// The menu's switch. Only meaningful on battery; on AC it is a no-op,
    /// since the charger resets it anyway.
    func setBatteryRecording(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isOnAC() else { return }
            self.batteryRecordingEnabled = enabled
            self.apply()
        }
    }

    /// Re-launch Whisper so it picks up changed launch settings — in the mode
    /// the power rule asks for, or not at all.
    ///
    /// Callers used to do this themselves, with a bare `stop()` then `start()`.
    /// On battery that started a *full* Whisper that nothing ever stopped again,
    /// a 1.8 GB model draining the battery until the charger came back.
    func restartIfShouldBeRunning(stop: @escaping () -> Void,
                                  start: @escaping (Mode) -> Void,
                                  delay: TimeInterval = 1.5) {
        guard let mode = desiredMode else {
            if isWhisperRunning() { stop() }
            runningMode = nil
            return
        }
        stop()
        runningMode = mode
        // PortAudio needs a beat to release the devices before the replacement
        // grabs them, or the new process inherits the same mess.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { start(mode) }
    }

    /// Sync Whisper to the current power source and menu switch. Main queue.
    private func apply() {
        let s = state
        if s != lastReportedState {
            lastReportedState = s
            onStateChanged?(s)
        }
        let want = desiredMode
        let running = isWhisperRunning()
        if want == nil {
            if running { onStop?() }
            runningMode = nil
            return
        }
        if running && runningMode == want { return }
        if running {
            // Wrong mode: stop, give PortAudio its beat, start the right one.
            onStop?()
            runningMode = want
            DispatchQueue.main.asyncAfter(deadline: .now() + switchDelay) { [weak self] in
                guard let self, self.desiredMode == want else { return }
                if !self.isWhisperRunning() { self.onStart?(want!) }
            }
        } else {
            runningMode = want
            onStart?(want!)
        }
    }

    /// Start Whisper now if it should be running and is not — the wake path,
    /// which must not wait up to a minute for the heartbeat. Main queue.
    func ensureRunning() {
        guard let want = desiredMode, !isWhisperRunning() else { return }
        runningMode = want
        onStart?(want)
    }

    /// Heartbeat: bring Whisper back if it died, in the mode it should be in.
    private func heartbeatTick() {
        guard let want = desiredMode, !isWhisperRunning() else { return }
        runningMode = want
        onStart?(want)
        onAutoRestart?(want)
    }
}
