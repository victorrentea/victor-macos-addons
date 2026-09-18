import Cocoa

/// Someone in the room pulled the secret FX link → announce **who** on a
/// bottom-center tab reading exactly `Marc Sánchez`: it rises from the bottom
/// edge, holds for three seconds, and falls back down on its own.
///
/// **Why a name and nothing else.** The press has already made itself heard —
/// the soundboard tile fires its sound and its paired visual at the same moment
/// this arrives — so the tile's name on the tab would only spell out what the
/// room just heard. The one fact nobody in the room supplies is *whose press it
/// was*: the trainer's own tablet, or the person he handed the link to. That is
/// all this tab carries, and it is why the tab carries no glyph either: a red
/// dot in front of a name is a second thing to read for no second fact.
///
/// It borrows `BellCard`'s surface exactly — same tab, same three seconds,
/// nothing to hover, nothing left behind — and differs in tint (red, the
/// button's own colour, against the bell's amber; with no glyph, the tint is
/// what says which of the two this is) and in staying **silent**: a chime on
/// top of a scream is noise, not information.
///
/// The name comes resolved from the daemon and is never a UUID; an unknown
/// holder is "Someone", the same word the bell uses, and an anonymous one is
/// marked with `BellCard.callerLabel` so the two surfaces cannot word it
/// differently.
///
/// **Latest-wins, no stacking.** Unlike the bell, a second press is not a second
/// person to name alongside the first: one link, one holder, one lever the room
/// shares past a cooldown. So a second press swaps the name on the live tab and
/// restarts the three seconds, rather than growing a list.
final class FxCard {
    private let banner: BottomTabBanner

    /// Who is currently named on the tab, or nil once it has finished falling.
    /// Exposed so the announcement state is assertable headlessly.
    private(set) var caller: String?

    /// The red of the button that was pressed. Deliberately not `BellCard`'s
    /// amber: the two share a surface and neither carries a glyph to tell them
    /// apart, so tint is the whole distinction.
    static let cardColor = NSColor.systemRed.withAlphaComponent(0.85)

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomTabBanner(screensProvider: screensProvider)
        banner.onDismissed = { [weak self] in self?.caller = nil }
    }

    /// `caller` pressed the button: show (or refresh) the tab. Safe to call
    /// repeatedly — each call restarts the three seconds.
    func show(caller: String, anonymous: Bool = false) {
        let who = BellCard.callerLabel(caller, anonymous: anonymous)
        self.caller = who
        banner.show(text: Self.cardText(caller: who), backgroundColor: Self.cardColor)
    }

    /// The exact tab copy: the name, and nothing else. Pure, so the wording is
    /// unit-testable, and total — a blank name still renders a word rather than
    /// an empty tab.
    static func cardText(caller: String) -> String {
        caller.nonBlank(or: "Someone")
    }

    /// Take the tab away early (it otherwise leaves on its own).
    func dismiss() {
        banner.dismiss()
    }

    /// True while the tab is on screen. (False in a headless test with no
    /// screens, since `BottomTabBanner` builds one panel per screen.)
    var isVisible: Bool { banner.isVisible }
}
