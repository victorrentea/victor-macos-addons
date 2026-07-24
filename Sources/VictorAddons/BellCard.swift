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

    /// Rings the chime from the start. `NSSound.play()` is a no-op while the
    /// sound is still playing, so without the stop() a second bell arriving
    /// within the previous ding (exactly the coalescing scenario) would be
    /// silent. Instance seam (`= Self.ringChime`) so unit tests can mute it.
    var playChime: () -> Void = BellCard.ringChime

    private static func ringChime() {
        guard let chime else { return }
        if chime.isPlaying { chime.stop() }
        chime.play()
    }

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
        playChime()
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
        let resolved = caller.nonBlank(or: "Someone")
        guard !callers.contains(resolved) else { return }
        callers.append(resolved)
        // A single append can only ever put the list one over the cap.
        if callers.count > Self.maxCallers {
            callers.removeFirst()
        }
    }

    /// The exact card copy for the active `callers`:
    ///   • one caller   → `🔔 Ana is calling you`   (the spec's exact wording)
    ///   • more callers → names joined with " + " and the plural "are", e.g.
    ///     `🔔 Ana + Dan are calling you`.
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

/// The one blank-proof display-name rule shared by every bell entry point —
/// `LocalWebSocketServer.bellCaller` (fallback "Someone", per the bell_ring
/// spec), `BellCard.addCaller` (same, for direct callers), and the `/test/bell`
/// wiring in AppDelegate (sample-name fallback "Ana Pop"). One definition so
/// the trim/empty rule can never drift between the three layers.
extension String {
    /// The trimmed string, or `fallback` when nothing readable remains.
    func nonBlank(or fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

extension Optional where Wrapped == String {
    /// `nonBlank(or:)` lifted over nil: an absent JSON field / query param
    /// resolves straight to `fallback` with no unwrapping dance at call sites.
    func nonBlank(or fallback: String) -> String {
        self?.nonBlank(or: fallback) ?? fallback
    }
}
