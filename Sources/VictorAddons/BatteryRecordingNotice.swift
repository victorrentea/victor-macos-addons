import Cocoa

/// 〰️🔴🔋 — the microphones are being written to disk while on battery.
///
/// On battery whisper only records (`TranscriptionController.Mode.captureOnly`);
/// the text arrives when the charger does. A microphone that records without
/// transcribing is a state worth seeing, so while it lasts the app's own
/// bottom-left pill says so (Victor, 2026-11-03).
///
/// **What it shows** (2026-11-05, Victor: *"waveform (luată din badge walkie
/// talkie, dar ne-animat/strălucit), un 🔴 care clipește lent, apoi emoji baterie
/// ca acum"*; it said `👂/🔋` until then): the sound, the red light of a take in
/// progress, why there is no text. The menu-bar icon stays 👂.
///
/// **Two buttons** (Victor, 2026-11-03: *"să aibă 2 butoane: snooze 1h ⏱️ +
/// Stop ❌"*; label `Stop ❌`), and only the buttons act — a click elsewhere on the pill does
/// nothing, so a stray one costs no meeting:
/// - `Snooze 1h ⏱️` (top; also a right-click) hides it for an hour, not for
///   good: an hour later, still on battery and still recording, it comes back.
///   The snooze lasts until the charger is plugged in — the next unplugging
///   shows it again at once.
/// - `Stop ❌` stops the recording until AC, exactly like the menu's `⏹ Stop
///   recording on battery` (`onStop`); the pill goes with it.
final class BatteryRecordingNotice {
    static let text = "🔋"
    static let snooze: TimeInterval = 3600
    static let color = NSColor.systemOrange.withAlphaComponent(0.85)

    private let screensProvider: () -> [NSScreen]
    private let now: () -> Date
    private var banner: BottomLeftBanner?
    private var snoozeTimer: Timer?
    private(set) var snoozedUntil: Date?
    private(set) var recording = false
    /// The `Stop ❌` button: switch the battery recording off (until AC).
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

    /// The `Stop ❌` button. The state change that follows takes the pill down.
    func stopNow() {
        overlayInfo("👂/🔋 battery recording stopped until AC")
        onStop?()
    }

    private func refresh() {
        let show = Self.shouldShow(recording: recording, snoozedUntil: snoozedUntil, now: now())
        if show, banner == nil {
            let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
            b.clickOnly = true
            b.icon = Self.waveform(size: 28, colour: .white)
            b.blinkingMark = Self.recordingDot(size: 28)
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

    /// Wispr Flow's five bars, as Walkie Talkie's chip wears them on its
    /// `Prompting` / `Transcribing` rows (`Glyphs.wisprBars`, traced off the app's
    /// own icon), drawn plain: the chip's ramp and glow are that row's, not the
    /// mark's. `v` counts down from the top of the box.
    private static let waveformBars: [(u: CGFloat, top: CGFloat, bottom: CGFloat)] = [
        (0.000, 0.000, 1.000),
        (0.209, 0.461, 0.891),
        (0.426, 0.164, 0.820),
        (0.643, 0.461, 0.898),
        (0.860, 0.000, 1.000),
    ]
    private static let waveformBarWidth: CGFloat = 0.140

    static func waveform(size: CGFloat, colour: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(colour.cgColor)
            let w = size * waveformBarWidth
            for bar in waveformBars {
                let top = rect.maxY - bar.top * size
                let bottom = rect.maxY - bar.bottom * size
                let box = CGRect(x: rect.minX + bar.u * size, y: bottom, width: w, height: top - bottom)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
            }
            ctx.fillPath()
            return true
        }
    }

    /// 🔴 as a picture: `BottomLeftBanner.blinkingMark` blinks a view, and a
    /// character in the label could only blink with the 🔋 beside it.
    static func recordingDot(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.9)]
            let dot = "🔴" as NSString
            let box = dot.size(withAttributes: attrs)
            dot.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2),
                     withAttributes: attrs)
            return true
        }
    }

    func stateJSON() -> String {
        let until = snoozedUntil.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        return "{\"recording\":\(recording),\"visible\":\(isVisible),\"snoozed_until\":\(until)}"
    }
}
