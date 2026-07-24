import Cocoa

/// A participant rang the attention bell → play a bell sound and show a
/// **persistent, hover-dismissible** bottom-left card reading exactly
/// `🔔 [Name] is calling you`.
///
/// Copied from the `SilentTranscriptionWarning` template: it owns a
/// `BottomLeftBanner(hoverable: true)`, sets `banner.onHover = { dismiss }`, and
/// shows with `hoverNudge: .down` and **no auto-fade timer** — the card stays
/// until the host hovers it away, at which point it leaves with the sinking
/// "put away" gesture (`dismissSinking`).
///
/// The bell card is deliberately NOT a native `NSUserNotification`: as with the
/// Group Photo / silent-transcription banners, macOS silently suppresses native
/// notifications for this locally-signed, un-entitled app while PowerPoint is
/// presenting fullscreen. The app's own always-on-top `BottomLeftBanner` shows
/// regardless — which is the whole point of ringing the trainer this way.
///
/// **Stacking:** when several bells arrive close together the card must not lose
/// a caller. The spec allows either a vertical stack of independent cards or a
/// single coalesced card listing callers; this uses the **coalesced** model —
/// one banner whose text lists every active caller (`🔔 Ana + Dan are calling
/// you`) — because it reuses the `BottomLeftBanner` primitive unchanged (it
/// anchors every panel flush to the screen's bottom edge, with no per-card
/// vertical offset). The caller list is capped so runaway bell-spam can't grow
/// the text without bound.
final class BellCard {
    private let banner: BottomLeftBanner

    /// Active callers currently represented on the card, oldest → newest. A
    /// hover clears the whole list (all callers acknowledged at once).
    private(set) var callers: [String] = []

    /// Cap on distinct callers shown at once (D3: "cap ~3"). Beyond this the
    /// oldest caller drops off, so the card text stays bounded under bell-spam.
    static let maxCallers = 3

    /// Warm amber/orange tint (D4 / task 2.4) — distinct from the *red*
    /// silent-transcription warning so the two never read as the same alert.
    static let cardColor = NSColor.systemOrange.withAlphaComponent(0.85)

    /// System "Glass" chime — a short bell-like ding. Chosen as a system sound
    /// (no new bundled asset) mirroring `SilentTranscriptionWarning`'s
    /// `NSSound(named: "Basso")`. Reads clearly as a bell/notification.
    private static let chime = NSSound(named: NSSound.Name("Glass"))

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomLeftBanner(screensProvider: screensProvider, hoverable: true)
        banner.onHover = { [weak self] in self?.dismiss() }
    }

    /// A bell arrived from `caller`: play the bell sound and show/refresh the
    /// persistent card with this caller added to the stack. Safe to call
    /// repeatedly — each call plays the sound and, for a *new* caller, widens the
    /// coalesced card; a repeat from a caller already shown re-plays the sound
    /// without duplicating their name.
    func show(caller: String) {
        addCaller(caller)
        Self.chime?.play()
        // NO auto-dismiss timer — the card is persistent by design. `.down`
        // previews the sinking "put away" exit that hovering triggers. The
        // caller-tinted (amber) pill still gets the hover whitening for feedback.
        banner.show(text: Self.cardText(callers: callers),
                    backgroundColor: Self.cardColor,
                    hoverNudge: .down)
    }

    /// Pure list update: append `caller` (de-duped by name), dropping the oldest
    /// once past `maxCallers`, and normalizing an empty/whitespace name to the
    /// neutral placeholder. Extracted so the stacking rule is unit-testable
    /// without rendering any panels.
    func addCaller(_ caller: String) {
        let name = caller.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = name.isEmpty ? "Someone" : name
        guard !callers.contains(resolved) else { return }
        callers.append(resolved)
        if callers.count > Self.maxCallers {
            callers.removeFirst(callers.count - Self.maxCallers)
        }
    }

    /// The exact card copy for the active `callers`:
    ///   • one caller  → `🔔 Ana is calling you`     (the spec's exact wording)
    ///   • more callers → `🔔 Ana + Dan is calling you` → uses "are" for plural,
    ///     e.g. `🔔 Ana + Dan are calling you`.
    /// Pure, so the wording is unit-testable.
    static func cardText(callers: [String]) -> String {
        switch callers.count {
        case 0:
            return "🔔 Someone is calling you"
        case 1:
            return "🔔 \(callers[0]) is calling you"
        default:
            return "🔔 \(callers.joined(separator: " + ")) are calling you"
        }
    }

    /// Hover-dismiss: clear the stack and slide the card straight down off the
    /// screen (the "put away" gesture), matching the silent-warning snooze exit.
    func dismiss() {
        callers.removeAll()
        banner.dismissSinking()
    }

    /// True while the card is on screen. (False in a headless test with no
    /// screens, since `BottomLeftBanner` builds one panel per screen.)
    var isVisible: Bool { banner.isVisible }
}
