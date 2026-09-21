import CoreGraphics
import Foundation

/// ⌘← / ⌘→ / ⌘⌫ turned into the control characters a terminal prompt understands.
///
/// Why this cannot be a Terminal.app setting, which is where it belongs:
/// Terminal's per-profile `keyMapBoundKeys` honours the `^` (control), `~`
/// (option) and `$` (shift) prefixes but **silently ignores `@` (command)**.
/// Measured on 2026-09-21 with a probe profile that gave each combination a
/// unique marker: `~007F` and `$007F` both arrived, while `@007F`, `@F702`,
/// `@F703` and `@~F702` produced nothing at all — ⌘← simply fell through as a
/// bare `ESC[D`. Not one of the 58 stock mappings in
/// `Terminal.app/Contents/Resources/keyMappings.plist` uses `@` either.
///
/// Control is no alternative: ⌃← and ⌃→ are macOS's own switch-Space hotkeys
/// (`AppleSymbolicHotKeys` 79–82, enabled on this Mac).
///
/// So the only place left to catch ⌘ is an event tap, ahead of AppKit.
enum TerminalPromptKeys {
    /// Apps whose prompt gets this treatment. Deliberately just Terminal.app:
    /// the target is the Claude Code prompt, and the focused app is as close to
    /// that as a tap can get. A plain shell is no worse off — `^A`/`^E` mean the
    /// same thing to zsh, and `^L` clears a screen that ⌘⌫ did nothing to before.
    static let scopeBundleIds: Set<String> = ["com.apple.Terminal"]

    private static let VK_LEFT: CGKeyCode = 0x7B
    private static let VK_RIGHT: CGKeyCode = 0x7C
    private static let VK_DELETE: CGKeyCode = 0x33

    /// What the rewritten event should become: the key it impersonates, and the
    /// character it carries.
    ///
    /// Both halves are set. The keycode alone is not enough — an event still
    /// carrying `characters` from the arrow it used to be can be read either
    /// way, depending on which of the two a terminal consults — and the
    /// character alone is not enough for the same reason in reverse.
    struct Rewrite: Equatable {
        let keyCode: CGKeyCode
        let character: Character
    }

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
        case VK_LEFT:   return Rewrite(keyCode: 0x00, character: "\u{01}")  // ⌃A — startOfLogicalLine
        case VK_RIGHT:  return Rewrite(keyCode: 0x0E, character: "\u{05}")  // ⌃E — endOfLogicalLine
        case VK_DELETE: return Rewrite(keyCode: 0x25, character: "\u{0C}")  // ⌃L — chat:clearInput
        default:        return nil
        }
    }
}
