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

    func testAPlainShellIsNot() {
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "~/workspace"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: "victor@Mac — -zsh — 120×40"))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: ""))
        XCTAssertFalse(ClaudeSessionTitle.isClaudeSession(title: nil))
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
