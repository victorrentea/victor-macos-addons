import Cocoa

/// A participant rang the attention bell → play a bell sound and announce *who*
/// rang it on a **bottom-center tab** reading exactly `🔔 Ana Pop`: it sneaks up
/// from the bottom edge, holds for three seconds, and falls back down on its own.
///
/// **Why a tab and not the old corner card.** This started life as a persistent,
/// hover-dismissible `BottomLeftBanner` pill saying `🔔 Ana is calling you` — the
/// same surface the app uses for things Victor must *act* on. But a bell is not a
/// decision; it is an announcement, and an announcement that waits in the corner
/// until it is acknowledged is a chore in the middle of a talk. So the bell now
/// uses `BottomTabBanner`: centred, where the eye already is, and gone by itself
/// three seconds later. Nothing to hover, nothing left behind.
///
/// The bell is deliberately NOT a native `NSUserNotification`: as with the Group
/// Photo / silent-transcription banners, macOS silently suppresses native
/// notifications for this locally-signed, un-entitled app while PowerPoint is
/// presenting fullscreen. The app's own always-on-top panel shows regardless —
/// which is the whole point of ringing the trainer this way.
///
/// **Stacking:** when several bells arrive close together the tab must not lose a
/// caller. It stays *one* tab whose text lists every active caller (`🔔 Ana +
/// Dan`), widening around them and restarting the three seconds — because a
/// second tab would have nowhere to go (they would both want the centre of the
/// bottom edge). The caller list is capped so runaway bell-spam can't grow the
/// text without bound.
final class BellCard {
    private let banner: BottomTabBanner

    /// Active callers currently named on the tab, oldest → newest. Cleared when
    /// the tab finishes falling, so the next bell starts a fresh announcement
    /// instead of resurrecting names nobody can still see.
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
        banner = BottomTabBanner(screensProvider: screensProvider)
        // The tab leaves on its own timer; when it is gone, so are the names.
        banner.onDismissed = { [weak self] in self?.callers.removeAll() }
    }

    /// A bell arrived from `caller`: play the bell sound and show/refresh the tab
    /// with this caller added to the stack. Safe to call repeatedly — each call
    /// plays the sound and restarts the three seconds; a *new* caller widens the
    /// tab, a repeat from a caller already named re-rings without duplicating it.
    ///
    /// `anonymous` (default `false`, so pre-flag call sites are unchanged) appends
    /// an "(anonymous)" marker to this caller's label — e.g. the tab then reads
    /// `🔔 Ana (anonymous)`. The marker is baked into the stored label, so
    /// coalescing/de-dup/cap all keep working unchanged.
    func show(caller: String, anonymous: Bool = false) {
        addCaller(Self.callerLabel(caller, anonymous: anonymous))
        playChime()
        banner.show(text: Self.cardText(callers: callers), backgroundColor: Self.cardColor)
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

    /// A single caller's display label: the resolved (blank-proof) name, with an
    /// "(anonymous)" marker appended when the ring was anonymous. Pure, so the
    /// marker wording is unit-testable and stays identical in the single-caller
    /// (`🔔 Ana (anonymous)`) and coalesced (`🔔 Ana (anonymous) + Dan`)
    /// renderings.
    static func callerLabel(_ caller: String, anonymous: Bool) -> String {
        let resolved = caller.nonBlank(or: "Someone")
        return anonymous ? "\(resolved) (anonymous)" : resolved
    }

    /// The exact tab copy for the active `callers`: the bell glyph and the names,
    /// nothing else. The old card spelled out "… is calling you"; on a tab that is
    /// up for three seconds that sentence costs width and reading time to say what
    /// the 🔔 already says. Names are joined with " + " when several ring at once
    /// (`🔔 Ana + Dan`). Pure, so the wording is unit-testable, and total — an
    /// empty list still renders a name rather than a bare bell.
    static func cardText(callers: [String]) -> String {
        let named = callers.isEmpty ? ["Someone"] : callers
        return "🔔 \(named.joined(separator: " + "))"
    }

    /// Take the tab away early (it otherwise leaves on its own): slide it down off
    /// the screen. The caller list clears from the banner's `onDismissed`, once
    /// the tab has actually gone.
    func dismiss() {
        banner.dismiss()
    }

    /// True while the tab is on screen. (False in a headless test with no
    /// screens, since `BottomTabBanner` builds one panel per screen.)
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
