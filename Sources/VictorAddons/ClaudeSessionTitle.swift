import Foundation

/// Is there a Claude Code session living in this Terminal window?
///
/// **The title is the only thing a window can be asked.** The Accessibility API
/// hands out geometry and a name and nothing else — no tty, no child process — so
/// the process table `ClaudeActivity` reads cannot be joined to a window at all.
/// Claude Code names the window itself while it runs: `✳ victor-macos-addons —
/// Terminal layout and cloud instances display` — the marker, the working
/// directory, and what the session is about. A shell that is not running one keeps
/// whatever the profile puts there, `~/workspace` on this Mac.
///
/// Measured 2026-09-11 against the fourteen Terminal windows open at the time:
/// twelve stars, two plain paths, and the stars included sessions sitting idle at
/// their prompt. **Idle is still running**, which is the whole point — a session
/// you are waiting on is exactly the one that must stay in sight. The signal
/// `ClaudeActivity` uses (a live `caffeinate`) is the wrong one here for the same
/// reason it is the right one for the lid: it drops five minutes after the last
/// turn, so a window would leave its quadrant and take someone else's on the next
/// ⌘⌃A, and a tile that lays the screen out differently on every press is not a
/// layout.
///
/// **The marker is animated, so it cannot be a list of glyphs.** The title carries
/// Claude's spinner, and a window title read through AX is that spinner sampled at
/// whatever frame it happened to be on. Measured 2026-09-21 on the six windows
/// then open: five stars and one `◐ Titlurile talkurilor BNPP octombrie` — pid
/// 27450, `entrypoint: cli`, an ordinary interactive session mid-turn, which the
/// old hardcoded asterisk set did not recognise. It was therefore treated as a
/// bare shell and pushed to the bottom of a pile on every ⌘⌃A, which is the exact
/// opposite of what the rule exists for (2026-09-21: *"să fie on top pe cât
/// posibil terminale claude interactive, nu alte terminale"*). Enumerating the
/// frames is a losing game — the asterisks were the whole alphabet until the moons
/// appeared — so what is tested is the *shape* of the marker instead.
///
/// The marker is the **first glyph**, never a substring: a session's title carries
/// a summary of what it is doing, and the word "claude" is as likely as not to be
/// in it.
enum ClaudeSessionTitle {

    /// The spinner frames seen in the wild, kept as documentation of what the
    /// shape test below has to keep accepting: the asterisks (2026-09-11) and the
    /// moon phases (2026-09-21). Not an allow-list — `isMarker` decides.
    static let markers: Set<Character> = ["✳", "✻", "✽", "✶", "✺", "✵",
                                          "◐", "◓", "◑", "◒"]

    static func isClaudeSession(title: String?) -> Bool {
        guard let first = title?.trimmingCharacters(in: .whitespaces).first else { return false }
        return isMarker(first)
    }

    /// A Claude marker is a **non-ASCII symbol from the typographic symbol
    /// blocks** — arrows through dingbats and the miscellaneous symbols after them
    /// (U+2190…U+2BFF), which is where every spinner frame Claude has drawn so far
    /// lives: `✳` U+2733 in Dingbats, `◐` U+25D0 in Geometric Shapes.
    ///
    /// The two bounds are what keeps this from swallowing ordinary titles. ASCII is
    /// out because `~` is a symbol to Unicode and `~/workspace` is what every shell
    /// window here is called. Everything above U+2BFF is out because that is where
    /// the emoji are, and a window titled by something else — `💬 Flux — …`, which
    /// `flux-agent.sh` sets on itself — is not a session Victor is typing into.
    static func isMarker(_ c: Character) -> Bool {
        guard c.isSymbol, !c.isASCII, let scalar = c.unicodeScalars.first else { return false }
        return (0x2190...0x2BFF).contains(scalar.value)
    }
}
