import CoreGraphics
import Foundation

/// ⌘← / ⌘→ / ⌘⌫ turned into the byte sequences a Claude Code prompt understands.
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
/// **Why each is a repeated sequence and not one control character.** The
/// obvious `^A`/`^E` are `startOfLogicalLine`/`endOfLogicalLine` — they stop at
/// the nearest newline, so in a dictated prompt they land at the start of the
/// *paragraph* you are in, not of the prompt. The one thing that crosses a
/// newline is `home`/`end` (`ESC[H` / `ESC[F`): `startOfLine()` jumps to the
/// *previous* row when the cursor is already at column 0, so pressing it over
/// and over walks to the very top. Same for `end` downwards, and same for `^U`
/// (`deleteToLineStart`, which shares that `startOfLine`) and `^K`
/// (`deleteToLineEnd`) — repeated, the pair empties the buffer from wherever
/// the cursor happens to sit.
///
/// Sending them as one multi-character event is safe: Terminal writes the whole
/// `characters` string to the pty verbatim (measured — a single event carrying
/// "XYZ" arrived as `XYZ`), and Claude Code's stdin parser splits it back into
/// that many keypresses. Repeats past the top or bottom are no-ops.
///
/// `escape` would clear the prompt in one keystroke, and is deliberately NOT
/// used: while a turn is running, escape aborts the turn instead. ⌘⌫ must never
/// be able to throw away a running response.
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

    private static let VK_LEFT: CGKeyCode = 0x7B
    private static let VK_RIGHT: CGKeyCode = 0x7C
    private static let VK_DELETE: CGKeyCode = 0x33

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
    private static let KILL_FORWARD = "\u{0b}"     // ^K
    private static let KILL_BACKWARD = "\u{15}"    // ^U

    /// `nil` = leave the event alone.
    ///
    /// Strict about the modifiers on purpose: ⌘ and nothing else. A stray ⇧ or ⌥
    /// means the user reached for something other than "jump to the end", and
    /// guessing on their behalf is how a remap becomes a thing you fight.
    static func rewrite(keyCode: CGKeyCode,
                        hasCommand: Bool, hasControl: Bool, hasOption: Bool, hasShift: Bool,
                        frontmostBundleId: String?) -> Rewrite? {
        guard hasCommand, !hasControl, !hasOption, !hasShift else { return nil }
        guard let bundleId = frontmostBundleId, scopeBundleIds.contains(bundleId) else { return nil }
        switch keyCode {
        case VK_LEFT:
            return Rewrite(keyCode: CARRIER, characters: String(repeating: HOME, count: reach))
        case VK_RIGHT:
            return Rewrite(keyCode: CARRIER, characters: String(repeating: END, count: reach))
        case VK_DELETE:
            // Forward first, then backward: together they clear the whole prompt
            // without the cursor having to be moved anywhere first.
            return Rewrite(keyCode: CARRIER,
                           characters: String(repeating: KILL_FORWARD, count: reach)
                                     + String(repeating: KILL_BACKWARD, count: reach))
        default:
            return nil
        }
    }
}
