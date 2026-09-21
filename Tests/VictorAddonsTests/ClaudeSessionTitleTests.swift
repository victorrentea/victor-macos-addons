import XCTest
@testable import VictorAddons

/// Which Terminal windows ⌘⌃A treats as "a session is running in there" — read
/// off the window title, because AX offers nothing else to read.
final class ClaudeSessionTitleTests: XCTestCase {

    /// Real titles, copied out of `/test/terminal-font` on 2026-09-11 with
    /// fourteen windows open.
    func testAStarredTitleIsASession() {
        XCTAssertTrue(ClaudeSessionTitle.isClaudeSession(
            title: "✳ victor-macos-addons — Terminal layout and cloud instances display"))
        XCTAssertTrue(ClaudeSessionTitle.isClaudeSession(
            title: "✳ workspace — Email către Laur cu Marketplace și Confluence"))
    }

    /// The title spinner animates, and AX reads one frame of it. This one is real
    /// too — `/test/terminal-font`, 2026-09-21, pid 27450, `entrypoint: cli`, a
    /// session mid-turn — and the asterisk-only detector called it a bare shell.
    func testAMoonPhaseIsTheSameSpinner() {
        XCTAssertTrue(ClaudeSessionTitle.isClaudeSession(
            title: "◐ Titlurile talkurilor BNPP octombrie"))
        for frame in ["◓", "◑", "◒", "✻", "✽", "✶", "✺", "✵"] {
            XCTAssertTrue(ClaudeSessionTitle.isClaudeSession(title: "\(frame) workspace — ceva"),
                          "frame \(frame) should read as a session")
        }
    }

    /// Every frame seen in the wild so far passes the shape test — the set is
    /// documentation, not the rule, and the two must not drift apart.
    func testTheDocumentedFramesAllPassTheShapeTest() {
        for marker in ClaudeSessionTitle.markers {
            XCTAssertTrue(ClaudeSessionTitle.isMarker(marker), "\(marker) should be a marker")
        }
    }

    func testAPlainShellIsNot() {
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "~/workspace"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "victor@Mac — -zsh — 120×40"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: ""))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: nil))
    }

    /// The shape test has to stay narrow at both ends: `~` is a symbol to Unicode
    /// and opens the title of every bare shell on this Mac, and an emoji opens the
    /// title of something that is not a session Victor types into — `flux-agent.sh`
    /// names its own window `💬 Flux — <subject>`.
    func testASymbolIsNotEnough() {
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "~/workspace/petclinic"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "💬 Flux — Invoice for training"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "🎬 recording"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "— workspace"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "Überprüfung"))
    }

    /// The star has to *open* the title. A session's title is a summary of what it
    /// is doing, and what it is doing is often Claude itself.
    func testTheWordClaudeInsideATitleProvesNothing() {
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "~/workspace/claude-docker"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(
            title: "vim ClaudeSessionTitle.swift — ✳"))
    }

    func testLeadingSpaceDoesNotHideTheStar() {
        XCTAssertTrue(ClaudeSessionTitle.isClaudeSession(title: "  ✳ workspace"))
    }
}
