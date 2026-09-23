import CoreGraphics
import Foundation

/// ⌘← / ⌘→ / ⌘⌫ / ⌘Z and ⇧↩ turned into the byte sequences a Claude Code prompt understands.
///
/// **Why this cannot be a Terminal.app setting**, which is where it belongs:
/// Terminal's per-profile `keyMapBoundKeys` honours the `^` (control), `~`
/// (option) and `$` (shift) prefixes but **silently ignores `@` (command)**.
/// Probed 2026-09-21 with a profile giving each combination a unique marker:
/// `~007F` and `$007F` arrived, while `@007F`, `@F702`, `@F703` and `@~F702`
/// produced nothing at all — ⌘← simply fell through as a bare `ESC[D`. Not one
/// of the 58 stock mappings in `keyMappings.plist` uses `@` either. Control is
/// no alternative: ⌃←/⌃→ are macOS's switch-Space hotkeys. So the only place
/// left to catch ⌘ is an event tap, ahead of AppKit.
///
/// **Why the jumps are a repeated sequence and not one control character.** The
/// obvious `^A`/`^E` are `startOfLogicalLine`/`endOfLogicalLine` — they stop at
/// the nearest newline, so in a dictated prompt they land at the start of the
/// *paragraph* you are in, not of the prompt. The one thing that crosses a
/// newline is `home`/`end` (`ESC[H` / `ESC[F`): `startOfLine()` jumps to the
/// *previous* row when the cursor is already at column 0, so pressing it over
/// and over walks to the very top. Same for `end` downwards.
///
/// Sending them as one multi-character event is safe: Terminal writes the whole
/// `characters` string to the pty verbatim (measured — a single event carrying
/// "XYZ" arrived as `XYZ`), and Claude Code's stdin parser splits it back into
/// that many keypresses. Repeats past the top or bottom are no-ops. 100 `home`s
/// in one 300-byte event were measured working (2026-09-22, Claude Code 2.1.278).
///
/// **Why ⌘⌫ is a pile of word kills, and not `^K`/`^U` or `^S`.** It sends
/// 100× `end` to reach the bottom of the prompt, then 1000× `ESC DEL`
/// (`backwardKillWord`), all in one event.
///
/// - `^K`/`^U` repeated would walk the rows too, but measured 2026-09-22: a chunk
///   of **40 or more** of those bare control characters is taken by Claude
///   Code's stdin for a paste and dropped whole, so they could only clear ~19 rows.
///   Escape sequences are exempt from that heuristic — 1000 `ESC[F`+`ESC DEL`
///   (≈2 KB) arrive as keypresses (measured 2026-09-23, Claude Code 2.1.280).
/// - `^S` (`chat:stash`) was the one-byte fix in between, but a stash is a
///   toggle: ⌘⌫ pressed again on the emptied prompt brought the text *back*.
///   Victor wants ⌘⌫ to be kamikaze — however many times, the prompt stays
///   empty — and restoring to be ⌘Z's job alone.
///
/// The kills land on Claude Code's undo stack as **one** snapshot (a burst of
/// edits is coalesced), so a single ⌘Z (`^_`, `chat:undo`) brings the whole
/// prompt back — measured on 25 rows. A second ⌘⌫ on the empty prompt changes
/// nothing, so it pushes nothing, and that one ⌘Z still restores the text.
///
/// A bare `escape` would clear the prompt in one keystroke too, and is
/// deliberately NOT used: while a turn is running, escape aborts the turn
/// instead. Every ESC sent here is glued to what follows it (`[F`, DEL) in the
/// same chunk, so it parses as a sequence, never as the escape key.
///
/// **⌘Z is `^_`** (`chat:undo`; also `undo` in zsh's emacs keymap).
///
/// **⇧↩ is `^J` (line feed)**: Claude Code inserts a newline without submitting,
/// same as ⌥↩. Stock Terminal sends a bare CR for ⇧↩, indistinguishable from ↩,
/// and — measured 2026-09-23 — a `$000D` entry in `keyMapBoundKeys` is ignored,
/// the same dead end as `@`. One byte and no ESC, so it can never read as
/// escape (which would abort a running turn).
enum TerminalPromptKeys {
    /// Apps whose prompt gets this treatment. Deliberately just Terminal.app:
    /// the target is the Claude Code prompt, and the focused app is as close to
    /// that as a tap can get. A plain shell is no worse off — `^U`/`^K` mean the
    /// same thing to zsh, and ⌘ arrows did nothing there before.
    static let scopeBundleIds: Set<String> = ["com.apple.Terminal"]

    /// How many rows one press is willing to travel. A prompt taller than this
    /// degrades gracefully (it moves this far and stops) rather than misbehaving,
    /// and a collapsed paste counts as the one row it draws, not its real height.
    static let reach = 100

    /// How many words one ⌘⌫ is willing to delete. Word, not row: a dictated
    /// prompt is one long wrapped paragraph.
    static let killReach = 1000

    private static let VK_LEFT: CGKeyCode = 0x7B
    private static let VK_RIGHT: CGKeyCode = 0x7C
    private static let VK_DELETE: CGKeyCode = 0x33
    private static let VK_RETURN: CGKeyCode = 0x24
    private static let VK_Z: CGKeyCode = 0x06

    /// What the rewritten event becomes. An event has to claim *some* key, but
    /// `characters` is what a terminal actually writes out, so the keycode is
    /// only a plausible carrier.
    struct Rewrite: Equatable {
        let keyCode: CGKeyCode
        let characters: String
    }

    private static let CARRIER: CGKeyCode = 0x00   // A

    private static let HOME = "\u{1b}[H"
    private static let END = "\u{1b}[F"
    private static let KILL_WORD = "\u{1b}\u{7f}"  // ESC DEL, backwardKillWord
    private static let UNDO = "\u{1f}"            // ^_, chat:undo
    private static let NEWLINE = "\n"             // ^J, newline without submit

    /// `nil` = leave the event alone.
    ///
    /// Strict about the modifiers on purpose: ⌘ and nothing else. A stray ⇧ or ⌥
    /// means the user reached for something other than "jump to the end", and
    /// guessing on their behalf is how a remap becomes a thing you fight.
    static func rewrite(keyCode: CGKeyCode,
                        hasCommand: Bool, hasControl: Bool, hasOption: Bool, hasShift: Bool,
                        frontmostBundleId: String?) -> Rewrite? {
        guard let bundleId = frontmostBundleId, scopeBundleIds.contains(bundleId) else { return nil }
        if keyCode == VK_RETURN, hasShift, !hasCommand, !hasControl, !hasOption {
            return Rewrite(keyCode: VK_RETURN, characters: NEWLINE)
        }
        guard hasCommand, !hasControl, !hasOption, !hasShift else { return nil }
        switch keyCode {
        case VK_LEFT:
            return Rewrite(keyCode: CARRIER, characters: String(repeating: HOME, count: reach))
        case VK_RIGHT:
            return Rewrite(keyCode: CARRIER, characters: String(repeating: END, count: reach))
        case VK_DELETE:
            return Rewrite(keyCode: CARRIER,
                           characters: String(repeating: END, count: reach)
                               + String(repeating: KILL_WORD, count: killReach))
        case VK_Z:
            return Rewrite(keyCode: CARRIER, characters: UNDO)
        default:
            return nil
        }
    }
}
