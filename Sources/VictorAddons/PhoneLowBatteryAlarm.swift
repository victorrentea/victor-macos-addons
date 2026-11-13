import Cocoa

/// When the corner pill about the phone's battery shows: a pure decision over
/// `PhoneCharge`'s reading.
///
/// Stricter than `PhoneBatteryPolicy`'s 30 or less, which is the tablet's limit: Victor
/// (2026-11-06) asked for this one under 30%. A dismissed pill stays away until the phone is
/// above 31%, so a charge wobbling around the limit cannot bring it back.
enum PhoneLowBatteryPolicy {
    static let showBelowPct = 30
    static let rearmAbovePct = 31

    /// Unplugged and fresh are `PhoneBatteryPolicy`'s rules: a phone on the charger needs no
    /// warning, and a flat one stops reporting.
    static func wantsPill(_ reading: PhoneCharge.Reading?, now: Date) -> Bool {
        guard let reading, reading.pct < showBelowPct else { return false }
        return PhoneBatteryPolicy.shouldWarn(reading, now: now)
    }

    static func rearms(_ reading: PhoneCharge.Reading?) -> Bool {
        (reading?.pct ?? 0) > rearmAbovePct
    }

    static func text(pct: Int) -> String { "🔋 Phone: \(pct)%" }
}

/// 🔋 The phone is running out: a red pill in the bottom-left corner that stays until Victor
/// clicks it, the same click-only pill as `MicDeadAlarm`. It follows the percentage while up.
///
/// The dismissal is kept in `UserDefaults`, because this app restarts on every deploy and the
/// pill must not come back with it.
final class PhoneLowBatteryAlarm {
    static let dismissedKey = "PhoneLowBattery.dismissed"

    private let screensProvider: () -> [NSScreen]
    private let defaults: UserDefaults
    private var banner: BottomLeftBanner?
    private var shownText: String?

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.pillScreens }, defaults: UserDefaults = .standard) {
        self.screensProvider = screensProvider
        self.defaults = defaults
    }

    var isRaised: Bool { banner != nil }
    private(set) var isDismissed: Bool {
        get { defaults.bool(forKey: Self.dismissedKey) }
        set { defaults.set(newValue, forKey: Self.dismissedKey) }
    }

    /// Every `PhoneCharge.pollInterval`, on the main thread.
    func update(_ reading: PhoneCharge.Reading?, now: Date) {
        if PhoneLowBatteryPolicy.rearms(reading) { isDismissed = false }
        guard !isDismissed, PhoneLowBatteryPolicy.wantsPill(reading, now: now), let reading else {
            takeDown()
            return
        }
        let text = PhoneLowBatteryPolicy.text(pct: reading.pct)
        if text == shownText { return }
        shownText = text
        if let banner {
            banner.updateText(text)
            return
        }
        overlayInfo("🔋 phone low: \(text)")
        let b = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        banner = b
        b.clickOnly = true
        b.onHover = { [weak self] in self?.dismiss() }
        // Right-click is the pill's "other exit"; here both mean "seen".
        b.onHoverCountdownExpired = { [weak self] in self?.dismiss() }
        b.show(text: text, backgroundColor: MicDeadAlarm.color, clickAction: .dismiss)
    }

    func dismiss() {
        overlayInfo("🔋 phone low: dismissed until it is above \(PhoneLowBatteryPolicy.rearmAbovePct)%")
        isDismissed = true
        takeDown()
    }

    private func takeDown() {
        banner?.dismissSinking()
        // The sinking exit runs on its own timer over panels it already holds.
        banner = nil
        shownText = nil
    }
}
