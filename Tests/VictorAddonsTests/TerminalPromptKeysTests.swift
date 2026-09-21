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

    private func rewrite(_ keyCode: CGKeyCode,
                         cmd: Bool = true, ctrl: Bool = false, opt: Bool = false, shift: Bool = false,
                         front: String? = "com.apple.Terminal") -> TerminalPromptKeys.Rewrite? {
        TerminalPromptKeys.rewrite(keyCode: keyCode,
                                   hasCommand: cmd, hasControl: ctrl, hasOption: opt, hasShift: shift,
                                   frontmostBundleId: front)
    }

    func testTheThreeEditsCarryTheControlCharactersThePromptReads() {
        // ^A / ^E / ^L are the three the Claude Code input handler binds to
        // startOfLogicalLine, endOfLogicalLine and chat:clearInput.
        XCTAssertEqual(rewrite(VK_LEFT)?.character, "\u{01}")
        XCTAssertEqual(rewrite(VK_RIGHT)?.character, "\u{05}")
        XCTAssertEqual(rewrite(VK_DELETE)?.character, "\u{0C}")
    }

    func testTheKeycodeIsRewrittenTooNotJustTheCharacter() {
        // A terminal may read either half; an event left claiming to be an arrow
        // while carrying ^A is read one way by one and the other way by another.
        XCTAssertEqual(rewrite(VK_LEFT)?.keyCode, 0x00)   // A
        XCTAssertEqual(rewrite(VK_RIGHT)?.keyCode, 0x0E)  // E
        XCTAssertEqual(rewrite(VK_DELETE)?.keyCode, 0x25) // L
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
}
