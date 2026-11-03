import Cocoa

/// 👂/🔋 — the microphones are being written to disk while on battery.
///
/// On battery whisper only records (`TranscriptionController.Mode.captureOnly`);
/// the text arrives when the charger does. A microphone that records without
/// transcribing is a state worth seeing, so while it lasts the app's own
/// bottom-left pill says `👂/🔋` (Victor, 2026-11-03).
///
/// **Two buttons** (Victor, 2026-11-03: *"să aibă 2 butoane: snooze 1h ⏱️ +
/// Stop ❌"*; label `Stop (until AC) ❌`), and only the buttons act — a click elsewhere on the pill does
/// nothing, so a stray one costs no meeting:
/// - `Snooze 1h ⏱️` (top; also a right-click) hides it for an hour, not for
///   good: an hour later, still on battery and still recording, it comes back.
///   The snooze lasts until the charger is plugged in — the next unplugging
///   shows it again at once.
/// - `Stop (until AC) ❌` stops the recording until AC, exactly like the menu's `⏹ Stop
///   recording on battery` (`onStop`); the pill goes with it.
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
    /// The `Stop (until AC) ❌` button: switch the battery recording off (until AC).
    var onStop: (() -> Void)?

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

    /// The `Stop (until AC) ❌` button. The state change that follows takes the pill down.
    func stopNow() {
        overlayInfo("👂/🔋 battery recording stopped until AC")
        onStop?()
    }

    private func refresh() {
        let show = Self.shouldShow(recording: recording, snoozedUntil: snoozedUntil, now: now())
        if show, banner == nil {
            let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
            b.clickOnly = true
            // Top button (and right-click) = snooze; bottom button = stop.
            b.onHoverCountdownExpired = { [weak self] in self?.snoozeNow() }
            b.onHover = { [weak self] in self?.stopNow() }
            b.show(text: Self.text, backgroundColor: Self.color,
                   autoAction: .snoozeHour, clickAction: .stopUntilAC)
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
