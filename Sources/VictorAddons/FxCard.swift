import Cocoa

/// Someone in the room pulled the secret FX link → announce it on a
/// **bottom-center tab** reading exactly `🔴 Ana Pop · scream ghost`: it rises
/// from the bottom edge, holds for three seconds, and falls back down on its own.
///
/// **Why an announcement and not an alert.** The press has already made itself
/// heard — the soundboard tile fires its sound and its paired visual at the same
/// moment this arrives. What the trainer cannot tell from the room is *who did
/// it*: his own tablet, or the person he handed the link to. That is the fact
/// this tab carries, so it borrows `BellCard`'s surface exactly — same tab, same
/// three seconds, nothing to hover, nothing left behind — and differs only in
/// tint (red, the button's own colour) and in staying **silent**: a chime on top
/// of a scream is noise, not information.
///
/// The name comes resolved from the daemon and is never a UUID; an unknown
/// holder is "Someone", the same word the bell uses, and an anonymous one is
/// marked with `BellCard.callerLabel` so the two surfaces cannot word it
/// differently.
///
/// **Latest-wins, no stacking.** Unlike the bell, a second press is not a second
/// person to name alongside the first: one link, one holder, one lever the room
/// shares past a cooldown. So a second press swaps the line on the live tab and
/// restarts the three seconds, rather than growing a list.
final class FxCard {
    private let banner: BottomTabBanner

    /// What is currently announced on the tab — the presser and the tile they
    /// fired — or nil once it has finished falling. Exposed so the announcement
    /// state is assertable headlessly.
    private(set) var announcement: (caller: String, label: String)?

    /// The red of the button that was pressed. Deliberately not `BellCard`'s
    /// amber: the two share a surface, so tint is the only thing telling them
    /// apart at a glance.
    static let cardColor = NSColor.systemRed.withAlphaComponent(0.85)

    init(screensProvider: @escaping () -> [NSScreen]) {
        banner = BottomTabBanner(screensProvider: screensProvider)
        banner.onDismissed = { [weak self] in self?.announcement = nil }
    }

    /// `caller` pressed the button and fired the tile named `label`: show (or
    /// refresh) the tab. Safe to call repeatedly — each call restarts the three
    /// seconds.
    func show(label: String, caller: String = "Someone", anonymous: Bool = false) {
        let who = BellCard.callerLabel(caller, anonymous: anonymous)
        let what = label.nonBlank(or: "a sound effect")
        announcement = (caller: who, label: what)
        banner.show(text: Self.cardText(caller: who, label: what), backgroundColor: Self.cardColor)
    }

    /// The exact tab copy: the red-button glyph, who pressed it, and what came
    /// out — the same economy as `BellCard.cardText`, for the same reason (a tab
    /// that is up for three seconds cannot afford a sentence). The name leads,
    /// because the sound has already said the rest. Pure, so the wording is
    /// unit-testable, and total — blank inputs still render words rather than a
    /// bare dot.
    static func cardText(caller: String, label: String) -> String {
        "🔴 \(caller.nonBlank(or: "Someone")) · \(label.nonBlank(or: "a sound effect"))"
    }

    /// Take the tab away early (it otherwise leaves on its own).
    func dismiss() {
        banner.dismiss()
    }

    /// True while the tab is on screen. (False in a headless test with no
    /// screens, since `BottomTabBanner` builds one panel per screen.)
    var isVisible: Bool { banner.isVisible }
}
