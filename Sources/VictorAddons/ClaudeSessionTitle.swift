import Foundation

/// Is there a Claude Code session living in this Terminal window?
///
/// **The title is the only thing a window can be asked.** The Accessibility API
/// hands out geometry and a name and nothing else — no tty, no child process — so
/// the process table `ClaudeActivity` reads cannot be joined to a window at all.
/// Claude Code names the window itself while it runs: `✳ victor-macos-addons —
/// Terminal layout and cloud instances display` — the star, the working directory,
/// and what the session is about. A shell that is not running one keeps whatever
/// the profile puts there, `~/workspace` on this Mac.
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
/// The marker is the **first glyph**, never a substring: a session's title carries
/// a summary of what it is doing, and the word "claude" is as likely as not to be
/// in it.
enum ClaudeSessionTitle {

    /// The glyphs Claude Code may open a window title with. `✳` is the one in use;
    /// the others are the rest of its spinner's asterisks — free to accept, and the
    /// obvious thing for a release to switch to.
    static let markers: Set<Character> = ["✳", "✻", "✽", "✶", "✺", "✵"]

    static func isClaudeSession(title: String?) -> Bool {
        guard let first = title?.trimmingCharacters(in: .whitespaces).first else { return false }
        return markers.contains(first)
    }
}
