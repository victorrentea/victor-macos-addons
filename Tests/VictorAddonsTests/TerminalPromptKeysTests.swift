import CoreGraphics
import XCTest
@testable import VictorAddons

/// The ⌘ edits for a terminal prompt. Each of these fails silently in the real
/// thing: a rewrite that fires too eagerly eats a keystroke the focused app
/// wanted, and one that fires too rarely just looks like the remap "didn't take"
/// — which is exactly how the Terminal.app `@`-prefix dead end cost an evening.
final class TerminalPromptKeysTests: XCTestCase {

    private let terminal = "com.apple.Terminal"
    private let VK_LEFT: CGKeyCode = 0x7B
    private let VK_RIGHT: CGKeyCode = 0x7C
    private let VK_DELETE: CGKeyCode = 0x33
    private let VK_RETURN: CGKeyCode = 0x24

    private func rewrite(_ keyCode: CGKeyCode,
                         cmd: Bool = true, ctrl: Bool = false, opt: Bool = false, shift: Bool = false,
                         front: String? = "com.apple.Terminal") -> TerminalPromptKeys.Rewrite? {
        TerminalPromptKeys.rewrite(keyCode: keyCode,
                                   hasCommand: cmd, hasControl: ctrl, hasOption: opt, hasShift: shift,
                                   frontmostBundleId: front)
    }

    func testTheJumpsRepeatSoTheyCrossNewlines() {
        // One `home` stops at the start of the wrapped row; it is the REPEAT that
        // walks to the top of the prompt, because startOfLine() steps to the
        // previous row once the cursor is already at column 0. A single keystroke
        // here is the bug Victor reported: "ma duce la startul RANDULUI".
        let reach = TerminalPromptKeys.reach
        XCTAssertEqual(rewrite(VK_LEFT)?.characters, String(repeating: "\u{1b}[H", count: reach))
        XCTAssertEqual(rewrite(VK_RIGHT)?.characters, String(repeating: "\u{1b}[F", count: reach))
        XCTAssertGreaterThan(reach, 1, "a single press cannot leave the current row")
    }

    func testDeleteIsASingleStashByte() {
        // ^S = chat:stash: empties the prompt whatever its height and keeps it
        // recoverable. It replaced 100×^K + 100×^U, which Claude Code's stdin
        // drops as a paste once the chunk reaches 40 control characters — so the
        // old ⌘⌫ silently did nothing on exactly the prompts worth clearing.
        XCTAssertEqual(rewrite(VK_DELETE)?.characters, "\u{13}")
    }

    func testDeleteStaysUnderThePasteThreshold() {
        // Measured 2026-09-22 on Claude Code 2.1.278: 39 control characters in
        // one chunk are keypresses, 40 are a paste and vanish.
        let chars = rewrite(VK_DELETE)?.characters ?? ""
        XCTAssertLessThan(chars.utf8.count, 40)
    }

    func testDeleteNeverSendsEscape() {
        // Escape would clear the prompt in one byte -- and abort a running turn.
        XCTAssertFalse(rewrite(VK_DELETE)?.characters.contains("\u{1b}") ?? true,
                       "escape must never ride on the clear-the-prompt key")
    }

    func testOnlyCommandAloneQualifies() {
        XCTAssertNil(rewrite(VK_LEFT, cmd: false), "no ⌘ at all is an ordinary arrow")
        XCTAssertNil(rewrite(VK_LEFT, ctrl: true), "⌘⌃← is somebody else's shortcut")
        XCTAssertNil(rewrite(VK_LEFT, opt: true))
        XCTAssertNil(rewrite(VK_LEFT, shift: true), "⌘⇧← is a selection, not a jump")
    }

    func testOnlyWhileATerminalIsFocused() {
        XCTAssertNil(rewrite(VK_LEFT, front: "com.microsoft.VSCode"),
                     "⌘← is start-of-line in every other Mac app already")
        XCTAssertNil(rewrite(VK_LEFT, front: nil),
                     "unknown frontmost app means leave the keyboard alone")
    }

    func testOtherKeysUnderCommandFallThrough() {
        // ⌘Q, ⌘W, ⌘T… must still reach the app, or this tap becomes unusable.
        for keyCode: CGKeyCode in [0x0C, 0x0D, 0x11, 0x7D, 0x7E] {
            XCTAssertNil(rewrite(keyCode), "keycode \(keyCode) is not ours to take")
        }
    }

    func testShiftReturnIsANewlineNotASubmit() {
        // ^J inserts a newline in Claude Code; a CR would send the prompt.
        XCTAssertEqual(rewrite(VK_RETURN, cmd: false, shift: true)?.characters, "\n")
        XCTAssertNil(rewrite(VK_RETURN, cmd: false), "plain ↩ must still submit")
        XCTAssertNil(rewrite(VK_RETURN, cmd: true, shift: true), "⌘⇧↩ is not ours")
        XCTAssertNil(rewrite(VK_RETURN, cmd: false, opt: true, shift: true))
        XCTAssertNil(rewrite(VK_RETURN, cmd: false, shift: true, front: "com.microsoft.VSCode"))
    }
}
