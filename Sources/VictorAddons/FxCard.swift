import Cocoa

/// Someone in the room pulled the secret FX link → announce it on a
/// **bottom-center tab** reading exactly `🔴 scream ghost`: it rises from the
/// bottom edge, holds for three seconds, and falls back down on its own.
///
/// **Why an announcement and not an alert.** The press has already made itself
/// heard — the soundboard tile fires its sound and its paired visual at the same
/// moment this arrives. What the trainer cannot tell from the room is *where it
/// came from*: his own tablet, or the person he handed the link to. That is the
/// one fact this tab carries, so it borrows `BellCard`'s surface exactly — same
/// tab, same three seconds, nothing to hover, nothing left behind — and differs
/// only in tint (red, the button's own colour) and in staying **silent**: a
/// chime on top of a scream is noise, not information.
///
/// **Latest-wins, no stacking.** Unlike the bell, two presses cannot be two
/// different people worth naming side by side — the link is anonymous by design
/// (see `FxFiredMsg` in the daemon), and back-to-back presses are the *same*
/// holder past the cooldown. So a second press swaps the label on the live tab
/// and restarts the three seconds, rather than growing a list.
final class FxCard {
    private let banner: BottomTabBanner

    /// The label currently on the tab, or nil once it has finished falling.
    /// Exposed so the announcement state is assertable headlessly.
    private(set) var label: String?

    /// The red of the button that was pressed. Deliberately not `BellCard`'s
    /// amber: the two share a surface, so tint is the only thing telling them
    /// apart at a glance.
    static let cardColor = NSColor.systemRed.withAlphaComponent(0.85)

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomTabBanner(screensProvider: screensProvider)
        banner.onDismissed = { [weak self] in self?.label = nil }
    }

    /// A press arrived for the tile named `label`: show (or refresh) the tab.
    /// Safe to call repeatedly — each call restarts the three seconds.
    func show(label: String) {
        let resolved = label.nonBlank(or: "a sound effect")
        self.label = resolved
        banner.show(text: Self.cardText(label: resolved), backgroundColor: Self.cardColor)
    }

    /// The exact tab copy: the red-button glyph and the tile's name, nothing
    /// else — the same economy as `BellCard.cardText`, for the same reason (a
    /// tab that is up for three seconds cannot afford a sentence). Pure, so the
    /// wording is unit-testable, and total — a blank label still renders words
    /// rather than a bare dot.
    static func cardText(label: String) -> String {
        "🔴 \(label.nonBlank(or: "a sound effect"))"
    }

    /// Take the tab away early (it otherwise leaves on its own).
    func dismiss() {
        banner.dismiss()
    }

    /// True while the tab is on screen. (False in a headless test with no
    /// screens, since `BottomTabBanner` builds one panel per screen.)
    var isVisible: Bool { banner.isVisible }
}
