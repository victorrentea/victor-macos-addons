import Cocoa

/// 🎤 The DJI transmitter has gone silent: a red tab at the bottom of every
/// screen that **stays until Victor clicks it**.
///
/// 2026-09-26: the clip-on transmitter's battery ran out after ~5 h of teaching
/// and he went on talking into a receiver that delivered nothing but zeros. The
/// receiver stays plugged in and perfectly healthy as a USB input, so nothing
/// else on the Mac noticed. `whisper-transcribe/dead_input.py` watches for that
/// — exact digital silence for 20 s while the input is the DJI receiver — and
/// prints `MIC_DIGITAL_SILENCE:<epoch>`; this is the half that makes it seen.
///
/// **Sticky, by design.** It does not leave when the audio comes back: a
/// transmitter that died for ten minutes is ten minutes missing from the
/// transcript, and Victor must know that even if he swapped the battery before
/// looking at the screen. Only his click takes it down. Re-arming is whisper's
/// job: it reports a dead run once, and only reports again after the audio has
/// come back and died a second time.
///
/// The look is `BottomTabBanner`'s — the same bottom-centre tab as the green
/// `🎤 Listening to` announcement, in red — and not `BottomLeftBanner`'s
/// hover-to-dismiss pill: a hover is too easy to give by accident while
/// reaching for the Dock, and this one must be acknowledged on purpose.
final class MicDeadAlarm {
    static let color = NSColor.systemRed.withAlphaComponent(0.85)
    /// Smaller than the tab's default 40 pt: the message is a sentence, and at
    /// 40 pt it would be truncated on the retina by the 60%-of-the-screen cap.
    static let fontSize: CGFloat = 30

    private let screensProvider: () -> [NSScreen]
    /// The Basso that goes with it — injectable so the tests stay silent.
    private let sound: () -> Void
    private var banner: BottomTabBanner?
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
        "🎤 DJI transmitter is silent — battery dead? (since \(hhmm(since)))"
    }

    /// The receiver's own word: no transmitter linked (`DjiReceiverMonitor`).
    /// Worded from the last battery level seen before the link went: at 6–7
    /// (DJI's own low warning and the shutdown step) it is almost certainly
    /// the battery; higher, it was switched off or walked out of range.
    static func linkLostText(since: Date, lastLevel: Int?) -> String {
        let why = (lastLevel ?? 0) >= 6 ? "battery dead" : "switched off or out of range"
        return "🎤 DJI transmitter gone — \(why)? (since \(hhmm(since)))"
    }

    /// Raise the alarm, or leave it alone if it is already up: the moment the
    /// FIRST run of silence began is the one worth reading, and a whisper
    /// restart re-reporting the same death must not move it.
    ///
    /// `screens` overrides where it is drawn — only the test hook uses it, to
    /// keep a test off the projected retina.
    func raise(since: Date, text custom: String? = nil, screens: (() -> [NSScreen])? = nil) {
        guard silentSince == nil else {
            overlayInfo("🎤 DJI silence reported again — the alarm is already up")
            return
        }
        silentSince = since
        let text = custom ?? Self.text(since: since)
        shownText = text
        overlayError("🎤❌ alarm raised: \(text)")
        let b = BottomTabBanner(screensProvider: screens ?? screensProvider)
        banner = b
        // Hold the banner until its fall has finished. Dropping it at the click
        // killed the fall's timer (it holds the banner weakly) and left the
        // panels on screen with nobody owning them — caught by the screenshot
        // check on 2026-09-26, the click-dismiss "worked" and the tab stayed.
        b.onDismissed = { [weak self, weak b] in
            if let self, self.banner === b { self.banner = nil }
        }
        b.show(text: text,
               backgroundColor: Self.color,
               font: NSFont.boldSystemFont(ofSize: Self.fontSize),
               hold: nil,
               onClick: { [weak self] in self?.acknowledge(by: "click") })
        sound()
    }

    /// Victor has seen it. The only way the tab leaves.
    func acknowledge(by how: String) {
        guard let since = silentSince else { return }
        overlayInfo("🎤 alarm dismissed (\(how)); it said: \(shownText ?? Self.text(since: since))")
        silentSince = nil
        banner?.dismiss()   // `onDismissed` lets go of it once it is off screen
    }

    /// Audio is flowing again. Logged only — the tab stays (see the type doc).
    func audioResumed() {
        overlayInfo("🎤 DJI audio is back" + (isRaised ? " — alarm stays up until clicked" : ""))
    }

    func stateJSON() -> String {
        let since = silentSince.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        let visible = banner?.isVisible ?? false
        return "{\"raised\":\(isRaised),\"silent_since\":\(since),\"visible\":\(visible)}"
    }
}

/// 🎤 The DJI transmitter's battery, when it is low: a 5-second tab,
/// `🎤 DJI TX battery ≈10 %`, shown each time the reading changes while it is
/// under 20 % (Victor: "să o afișezi din % în % pentru 5 sec când e sub 20 %").
/// On the receiver's 7-step gauge that is twice: level 6 (DJI's own warning)
/// and level 7 (shutdown follows). Orange for the first, red for the last.
final class DjiBatteryTab {
    static let hold: TimeInterval = 5
    private var banners: [BottomTabBanner] = []

    static func text(percent: Int) -> String { "🎤 DJI TX battery ≈\(percent) %" }

    func show(level: Int, percent: Int, screens: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        let text = Self.text(percent: percent)
        overlayInfo("🎤 battery tab: \(text) (raw level \(level)/7)")
        let b = BottomTabBanner(screensProvider: screens)
        banners.append(b)
        b.onDismissed = { [weak self, weak b] in self?.banners.removeAll { $0 === b } }
        b.show(text: text,
               backgroundColor: (level >= 7 ? NSColor.systemRed : NSColor.systemOrange).withAlphaComponent(0.85),
               hold: Self.hold)
    }
}
