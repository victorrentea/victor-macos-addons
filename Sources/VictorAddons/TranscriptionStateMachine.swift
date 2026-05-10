import Foundation

/// Runtime state machine for the transcription feature.
///
/// Mirrors the spec at `docs/transcription-state.puml`. Owns the persisted
/// (state, wasOn) pair in UserDefaults and emits Whisper start/stop side
/// effects via callbacks. Callers feed it events; the machine handles the
/// guards and persistence.
final class TranscriptionStateMachine {
    enum State: String, Equatable {
        case off
        case on
        case onWorkday
        case battery
    }

    // Side-effect callbacks
    var onStartWhisper: (() -> Void)?
    var onStopWhisper: (() -> Void)?
    var onStateChanged: ((State, Bool) -> Void)?

    private(set) var state: State
    /// Only meaningful when `state == .battery`. Tracks whether the
    /// running state we paused was `.on` (off-hours session).
    private(set) var wasOn: Bool

    private let isWhisperRunning: () -> Bool

    private static let stateKey = "transcriptionState"
    private static let wasOnKey = "transcriptionWasOn"
    private static let legacyKey = "transcribingEnabled"

    init(isWhisperRunning: @escaping () -> Bool) {
        self.isWhisperRunning = isWhisperRunning
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.stateKey), let parsed = State(rawValue: raw) {
            self.state = parsed
        } else if let legacy = defaults.object(forKey: Self.legacyKey) as? Bool {
            self.state = legacy ? .on : .off
        } else {
            self.state = .on
        }
        self.wasOn = defaults.bool(forKey: Self.wasOnKey)
    }

    /// Apply current conditions to the saved state — implements the
    /// Restore + Settle table in the diagram. Call once on launch.
    func settle(now: Date = Date()) {
        let inside = TranscriptionScheduler.isLockedOn(at: now)
        let onAC = PowerMonitor.isOnAC()
        let target = resolveSettleTarget(saved: state, savedWasOn: wasOn, inside: inside, onAC: onAC)
        persist(state: target.0, wasOn: target.1)
        // On launch the process is always not-running, so fire start/stop based on target.
        if isRunningState(target.0) {
            onStartWhisper?()
        } else {
            onStopWhisper?()
        }
        onStateChanged?(target.0, target.1)
    }

    private func resolveSettleTarget(saved: State, savedWasOn: Bool, inside: Bool, onAC: Bool) -> (State, Bool) {
        if !onAC {
            // On battery: every saved state collapses to .battery, with
            // wasOn derived from saved (On→true, OnWorkday/Off→false,
            // Battery→preserved).
            switch saved {
            case .off:                  return (.battery, false)
            case .on:                   return (.battery, true)
            case .onWorkday:            return (.battery, false)
            case .battery:              return (.battery, savedWasOn)
            }
        }
        // On AC.
        if inside {
            // Inside workday window: any non-Off saved state collapses to .onWorkday.
            // Off + inside + AC also settles forward via heartbeat semantics.
            return (.onWorkday, false)
        }
        // On AC, off-hours.
        switch saved {
        case .off:                            return (.off, false)
        case .on:                             return (.on, false)
        case .onWorkday:                      return (.off, false)  // settled past 18:00
        case .battery where savedWasOn:       return (.on, false)
        case .battery:                        return (.off, false)
        }
    }

    // ── Events ───────────────────────────────────────────────────────

    /// User clicked the menu item in `.off` (which advertises "Start Transcribing").
    func userClickStart() {
        guard state == .off else { return }
        transition(to: .on, wasOn: false)
    }

    /// User clicked the menu item in `.on` (which advertises "Stop Transcribing").
    func userClickStop() {
        guard state == .on else { return }
        transition(to: .off, wasOn: false)
    }

    /// 09:00 Mon–Fri boundary (entering the workday window).
    func enterWorkday() {
        switch state {
        case .off:
            if PowerMonitor.isOnAC() { transition(to: .onWorkday, wasOn: false) }
        case .on:
            transition(to: .onWorkday, wasOn: false)
        case .onWorkday, .battery:
            break
        }
    }

    /// 18:00 Mon–Fri boundary (leaving the workday window).
    func exitWorkday() {
        if state == .onWorkday {
            transition(to: .off, wasOn: false)
        }
        // .battery: no-op; wasOn preserved
    }

    /// Called every 60s while inside the workday window.
    func heartbeat() {
        guard TranscriptionScheduler.isLockedOn() else { return }
        let onAC = PowerMonitor.isOnAC()
        switch state {
        case .off where onAC:
            transition(to: .onWorkday, wasOn: false)
        case .onWorkday where onAC && !isWhisperRunning():
            // In-place restart, no state change.
            onStartWhisper?()
        default:
            break
        }
    }

    func switchToBattery() {
        switch state {
        case .on:        transition(to: .battery, wasOn: true)
        case .onWorkday: transition(to: .battery, wasOn: false)
        case .off:       transition(to: .battery, wasOn: false)
        case .battery:   break
        }
    }

    func switchToAC() {
        guard state == .battery else { return }
        let inside = TranscriptionScheduler.isLockedOn()
        if inside {
            transition(to: .onWorkday, wasOn: false)
        } else if wasOn {
            transition(to: .on, wasOn: false)
        } else {
            transition(to: .off, wasOn: false)
        }
    }

    // ── Core transition ──────────────────────────────────────────────

    private func transition(to newState: State, wasOn newWasOn: Bool) {
        let wasRunning = isRunningState(state)
        let nowRunning = isRunningState(newState)
        persist(state: newState, wasOn: newWasOn)
        if nowRunning && !wasRunning {
            onStartWhisper?()
        } else if !nowRunning && wasRunning {
            onStopWhisper?()
        }
        onStateChanged?(newState, newWasOn)
    }

    private func persist(state newState: State, wasOn newWasOn: Bool) {
        state = newState
        wasOn = newWasOn
        let defaults = UserDefaults.standard
        defaults.set(newState.rawValue, forKey: Self.stateKey)
        defaults.set(newWasOn, forKey: Self.wasOnKey)
    }

    private func isRunningState(_ s: State) -> Bool {
        s == .on || s == .onWorkday
    }
}
