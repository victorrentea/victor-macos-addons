import XCTest
@testable import VictorAddons

/// Which key the ⌘⇧V bezel presses. ⌃V exists for exactly one case — an image
/// clip landing in a Claude Code prompt, the only place on this Mac that reads
/// the clipboard itself; everything else keeps ⌘V.
final class ClipboardPasteKeystrokeTests: XCTestCase {

    private let terminal = "com.apple.Terminal"
    /// A real Claude Code window title: the spinner, the working directory, and
    /// what the session is about.
    private let claudeTitle = "✳ victor-macos-addons — Clipboard bezel paste key"
    /// What a Terminal window with no session in it is called here.
    private let shellTitle = "~/workspace"

    func testAnImageIntoAClaudeSessionGoesOutAsControlV() {
        XCTAssertEqual(.control,
                       ClipboardPasteKeystroke.choose(isImage: true,
                                                      frontmostBundleID: terminal,
                                                      focusedWindowTitle: claudeTitle))
    }

    /// Text already pastes into a terminal with ⌘V, through bracketed paste and
    /// without a subprocess. Nothing to fix, so nothing changes.
    func testTextIntoTheSameSessionStaysCommandV() {
        XCTAssertEqual(.command,
                       ClipboardPasteKeystroke.choose(isImage: false,
                                                      frontmostBundleID: terminal,
                                                      focusedWindowTitle: claudeTitle))
    }

    /// ⌃V at a shell prompt is `quoted-insert`: it eats the next keystroke. A
    /// ⌘V that pastes nothing is the better failure.
    func testAnImageIntoABareShellStaysCommandV() {
        XCTAssertEqual(.command,
                       ClipboardPasteKeystroke.choose(isImage: true,
                                                      frontmostBundleID: terminal,
                                                      focusedWindowTitle: shellTitle))
    }

    /// Copilot CLI has no clipboard-image path at all, and does not mark its
    /// window either — so it lands here, on the title test, and keeps ⌘V.
    func testATerminalWithNoTitleStaysCommandV() {
        XCTAssertEqual(.command,
                       ClipboardPasteKeystroke.choose(isImage: true,
                                                      frontmostBundleID: terminal,
                                                      focusedWindowTitle: nil))
    }

    func testEveryOtherAppKeepsCommandV() {
        for bundleID in ["com.apple.Safari", "com.google.Chrome", "com.googlecode.iterm2", nil] {
            XCTAssertEqual(.command,
                           ClipboardPasteKeystroke.choose(isImage: true,
                                                          frontmostBundleID: bundleID,
                                                          focusedWindowTitle: claudeTitle),
                           "\(bundleID ?? "nil") must not get ⌃V")
        }
    }

    /// The marker is animated — the asterisks became moons once already — so the
    /// bezel has to recognise a session by the same shape test `⌘⌃A` uses, not
    /// by a list of glyphs.
    func testTheSpinnerFramesAllCount() {
        for marker in ClaudeSessionTitle.markers {
            XCTAssertEqual(.control,
                           ClipboardPasteKeystroke.choose(isImage: true,
                                                          frontmostBundleID: terminal,
                                                          focusedWindowTitle: "\(marker) petclinic — something"),
                           "frame \(marker) must be recognised as a session")
        }
    }
}
