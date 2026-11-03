import Cocoa

/// 👂/🔋 — the microphones are being written to disk while on battery.
///
/// On battery whisper only records (`TranscriptionController.Mode.captureOnly`);
/// the text arrives when the charger does. A microphone that records without
/// transcribing is a state worth seeing, so while it lasts the app's own
/// bottom-left pill says `👂/🔋` (Victor, 2026-11-03).
///
/// **A click snoozes it for an hour**, not for good: an hour later, still on
/// battery and still recording, it comes back. The snooze lasts until the
/// charger is plugged in — the next unplugging shows it again at once.
/// Stopping the recording itself is the menu's job (`⏹ Stop recording on
/// battery`), not the pill's: a stray click must never cost a meeting.
final class BatteryRecordingNotice {
    static let text = "👂/🔋"
    static let snooze: TimeInterval = 3600
    static let color = NSColor.systemOrange.withAlphaComponent(0.85)

    private let screensProvider: () -> [NSScreen]
    private let now: () -> Date
    private var banner: BottomLeftBanner?
    private var snoozeTimer: Timer?
    private(set) var snoozedUntil: Date?
    private(set) var recording = false

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.physical },
         now: @escaping () -> Date = Date.init) {
        self.screensProvider = screensProvider
        self.now = now
    }

    var isVisible: Bool { banner?.isVisible ?? false }

    /// Whether the pill should be up — the policy, without any AppKit.
    static func shouldShow(recording: Bool, snoozedUntil: Date?, now: Date) -> Bool {
        guard recording else { return false }
        guard let until = snoozedUntil else { return true }
        return now >= until
    }

    /// Main thread. Call on every `TranscriptionController.State` change.
    func update(_ state: TranscriptionController.State) {
        recording = state == .recordingOnBattery
        if state == .onAC {
            // The charger ends the snooze: the next battery stretch shows at once.
            snoozedUntil = nil
            snoozeTimer?.invalidate()
            snoozeTimer = nil
        }
        refresh()
    }

    /// The pill was clicked (or right-clicked).
    func snoozeNow() {
        snoozedUntil = now().addingTimeInterval(Self.snooze)
        overlayInfo("👂/🔋 snoozed until \(MicDeadAlarm.hhmm(snoozedUntil!))")
        snoozeTimer?.invalidate()
        let t = Timer(timeInterval: Self.snooze, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        snoozeTimer = t
        refresh()
    }

    private func refresh() {
        let show = Self.shouldShow(recording: recording, snoozedUntil: snoozedUntil, now: now())
        if show, banner == nil {
            let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
            b.clickOnly = true
            b.onHover = { [weak self] in self?.snoozeNow() }
            b.onHoverCountdownExpired = { [weak self] in self?.snoozeNow() }
            b.show(text: Self.text, backgroundColor: Self.color, clickAction: .snoozeHour)
            banner = b
        } else if !show, let b = banner {
            b.dismissSinking()
            banner = nil
        }
    }

    func stateJSON() -> String {
        let until = snoozedUntil.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        return "{\"recording\":\(recording),\"visible\":\(isVisible),\"snoozed_until\":\(until)}"
    }
}
