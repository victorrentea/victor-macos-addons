import XCTest
@testable import VictorAddons

/// ⌘⌃P (and the 🤖 menu row) are only "sent to the training assistant" because
/// of the exact shape of the line they append: `training-assistant` keeps NO
/// separate prompt store — it re-reads the session notes file and builds the
/// participants' Prompts tab out of the 🤖-stamped lines
/// (`daemon/misc/content_files.py`, `_PROMPT_LINE_RE` / `parse_prompts`).
///
/// That makes the marker a wire format between two repos that are never built
/// together, and a wire format nobody asserts is one a refactor renames for
/// free: drop the "- " bullet, or write "🤖:" instead of "🤖 ", and every prompt
/// silently stops reaching the room while the notes still look right on this
/// side. The Python side pins the parse; this pins the emit, against a literal
/// copy of that regex.
final class SessionNotesPromptLineTests: XCTestCase {
    /// `daemon/misc/content_files.py::_PROMPT_LINE_RE`, transcribed.
    private let promptLineRE = try! NSRegularExpression(pattern: "^-\\s*\\x{1F916}\\x{FE0F}?\\s*(.*)$")

    private var folder: URL!
    private var notes: URL!
    private var savedSessionFolder: URL?

    override func setUpWithError() throws {
        savedSessionFolder = ScreenshotManager.sessionFolder
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notes-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        notes = folder.appendingPathComponent("session - notes.txt")
        try "".write(to: notes, atomically: true, encoding: .utf8)
        ScreenshotManager.sessionFolder = folder
    }

    override func tearDownWithError() throws {
        ScreenshotManager.sessionFolder = savedSessionFolder
        try? FileManager.default.removeItem(at: folder)
    }

    private func lines() throws -> [String] {
        try String(contentsOf: notes, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// The captured group is what the room is shown, so it has to be the prompt
    /// itself — marker and bullet stripped, nothing else lost.
    private func parsedPrompt(_ line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = promptLineRE.firstMatch(in: line, range: range),
              let captured = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[captured])
    }

    func testAgentPromptLineParsesAsAPromptForTheRoom() throws {
        try SessionNotesAppender.writeNotes("start db,be,fe", marker: .agentPrompt)
        let line = try XCTUnwrap(lines().first)
        XCTAssertEqual(line, "- 🤖 start db,be,fe")
        XCTAssertEqual(parsedPrompt(line), "start db,be,fe")
    }

    /// The other marker must NOT reach the Prompts tab: 📋 is Victor sending
    /// something by hand to the notes, and the room's prompt list is meant to be
    /// what went to an agent.
    func testHandSentLineIsNotAPrompt() throws {
        try SessionNotesAppender.writeNotes("https://example.com", marker: .sentByHand)
        let line = try XCTUnwrap(lines().first)
        XCTAssertEqual(line, "- 📋 https://example.com")
        XCTAssertNil(parsedPrompt(line))
    }

    /// Two prompts in a row must be two entries, which is only true if each
    /// append ends its own line — the daemon walks the file line by line.
    func testConsecutivePromptsEachGetTheirOwnLine() throws {
        try SessionNotesAppender.writeNotes("first", marker: .agentPrompt)
        try SessionNotesAppender.writeNotes("second", marker: .agentPrompt)
        XCTAssertEqual(try lines().prefix(2).map { $0 }, ["- 🤖 first", "- 🤖 second"])
    }

    /// A pasted multi-line prompt keeps its newlines and only the FIRST line is
    /// stamped — the daemon's rule for continuation lines (non-blank, not a new
    /// bullet, not a "===" header) is what re-joins them, so the body must not
    /// arrive bulleted.
    func testMultilinePromptStampsOnlyItsFirstLine() throws {
        try SessionNotesAppender.writeNotes("refactor this\nand run the tests", marker: .agentPrompt)
        XCTAssertEqual(try lines().prefix(2).map { $0 }, ["- 🤖 refactor this", "and run the tests"])
    }

    /// Without a session there is no room to send to, and the caller must be
    /// able to say so on the pill rather than silently swallow the prompt.
    func testNoSessionThrowsRatherThanSwallowing() {
        ScreenshotManager.sessionFolder = nil
        XCTAssertThrowsError(try SessionNotesAppender.writeNotes("nowhere", marker: .agentPrompt)) { error in
            XCTAssertEqual(error as? SessionNotesAppender.NotesError, .noSession)
        }
    }
}
