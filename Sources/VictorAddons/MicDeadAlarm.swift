import Cocoa

/// 🎤 The DJI transmitter is gone: a red pill in the bottom-left corner of
/// every screen that **stays until Victor clicks it**.
///
/// 2026-09-26: the clip-on transmitter's battery ran out after ~5 h of teaching
/// and he went on talking into a receiver that delivered nothing but zeros.
/// Two sources raise it: the receiver's own "no transmitter linked"
/// (`DjiReceiverMonitor`, the real signal) and, when that USB status cannot be
/// read, whisper's exact-digital-silence guess (`dead_input.py`).
///
/// **The app's own notification**, `BottomLeftBanner` — the same corner pill
/// as every other message here (Victor: *"notificarea trebuie dată din macOS
/// Addons în stilul ei, overlay stânga jos"*), tinted red like the roaming
/// warning. **Sticky and click-only** (`clickOnly`): it does not leave when the
/// transmitter comes back — minutes missing from the transcript are worth
/// knowing even after the battery was swapped — and, unlike the roaming pill,
/// a hover does not dismiss it: only a deliberate click (left or right).
/// Re-arming is the sources' job: each reports a dead run once, and again only
/// after the audio / link came back and went again.
final class MicDeadAlarm {
    static let color = NSColor.systemRed.withAlphaComponent(0.85)
    /// Smaller than the corner pill's 54 pt: the message is a sentence, and the
    /// pill caps at half the screen — at 54 pt it would be cut on the retina.
    static let fontSize: CGFloat = 34

    private let screensProvider: () -> [NSScreen]
    /// The Basso that goes with it — injectable so the tests stay silent.
    private let sound: () -> Void
    private var banner: BottomLeftBanner?
    private(set) var silentSince: Date?
    private var shownText: String?

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens },
         sound: @escaping () -> Void = { NSSound(named: NSSound.Name("Basso"))?.play() }) {
        self.screensProvider = screensProvider
        self.sound = sound
    }

    var isRaised: Bool { silentSince != nil }

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        // POSIX, or the user's 12-hour override turns HH into "3:10 PM".
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// Whisper's guess: the receiver is streaming exact zeros.
    static func text(since: Date) -> String {
        "🎤 DJI TX silent since \(hhmm(since)) — battery dead?"
    }

    /// The receiver's own word: no transmitter linked (`DjiReceiverMonitor`).
    /// Worded from the last battery level seen before the link went: at 6–7
    /// (DJI's own low warning and the shutdown step) it is almost certainly
    /// the battery; higher, it was switched off or walked out of range.
    static func linkLostText(since: Date, lastLevel: Int?) -> String {
        let why = (lastLevel ?? 0) >= 6 ? "battery dead?" : "off or out of range?"
        return "🎤 DJI TX gone since \(hhmm(since)) — \(why)"
    }

    /// Raise the alarm, or leave it alone if it is already up: the moment the
    /// FIRST run began is the one worth reading, and a repeat report of the
    /// same death must not move it.
    ///
    /// `screens` overrides where it is drawn — only the test hooks use it, to
    /// keep a test off the projected retina.
    func raise(since: Date, text custom: String? = nil, screens: (() -> [NSScreen])? = nil) {
        guard silentSince == nil else {
            overlayInfo("🎤 DJI reported dead again — the alarm is already up")
            return
        }
        silentSince = since
        let text = custom ?? Self.text(since: since)
        shownText = text
        overlayError("🎤❌ alarm raised: \(text)")
        let b = BottomLeftBanner(screensProvider: screens ?? screensProvider, hoverable: true)
        banner = b
        b.clickOnly = true
        b.onHover = { [weak self] in self?.acknowledge(by: "click") }
        // Right-click is the pill's "other exit"; for an alarm both mean "seen".
        b.onHoverCountdownExpired = { [weak self] in self?.acknowledge(by: "right-click") }
        b.show(text: text,
               backgroundColor: Self.color,
               font: NSFont.boldSystemFont(ofSize: Self.fontSize))
        sound()
    }

    /// Victor has seen it. The only way the pill leaves.
    func acknowledge(by how: String) {
        guard let since = silentSince else { return }
        overlayInfo("🎤 alarm dismissed (\(how)); it said: \(shownText ?? Self.text(since: since))")
        silentSince = nil
        banner?.dismissSinking()
        // The sinking exit runs on its own timer over panels it already holds.
        banner = nil
    }

    /// Audio / link is back. Logged only — the pill stays (see the type doc).
    func audioResumed() {
        overlayInfo("🎤 DJI is back" + (isRaised ? " — alarm stays up until clicked" : ""))
    }

    func stateJSON() -> String {
        let since = silentSince.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        let visible = banner?.isVisible ?? false
        return "{\"raised\":\(isRaised),\"silent_since\":\(since),\"visible\":\(visible)}"
    }
}

/// 🎤 The DJI transmitter's battery, when it is low: the app's ordinary
/// bottom-left notification for 5 s, `🎤 DJI TX battery ≈10 %`, each time the
/// reading changes while it is under 20 % (Victor: "să o afișezi din % în %
/// pentru 5 sec când e sub 20 %"). On the receiver's 7-step gauge that is
/// twice: level 6 (DJI's own warning) and level 7 (shutdown follows).
///
/// Shown through the app's shared `StatusBanner` (`show`), so it takes its
/// turn with every other corner message instead of stacking on top of one.
final class DjiBatteryNotice {
    static let hold: TimeInterval = 5
    private let show: (String) -> Void

    init(show: @escaping (String) -> Void) { self.show = show }

    static func text(percent: Int) -> String { "🎤 DJI TX battery ≈\(percent) %" }

    func show(level: Int, percent: Int) {
        let text = Self.text(percent: percent)
        overlayInfo("🎤 battery notice: \(text) (raw level \(level)/7)")
        show(text)
    }
}
