import XCTest
import CoreGraphics
@testable import VictorAddons

/// The rule these guard: an unattended agent window ALWAYS closes itself —
/// except for the one verdict that means Victor is expected at that window,
/// because his mail asked for an interactive session.
final class FluxAgentVerdictTests: XCTestCase {

    func testOkAndFailBothCloseTheWindow() {
        XCTAssertTrue(FluxAgentVerdict.closesWindow(rawVerdict: "ok"))
        XCTAssertTrue(FluxAgentVerdict.closesWindow(rawVerdict: "fail"))
    }

    func testInteractiveKeepsTheWindow() {
        XCTAssertFalse(FluxAgentVerdict.closesWindow(rawVerdict: "interactive"))
        // `do shell script` hands back whatever the file held, newline included.
        XCTAssertFalse(FluxAgentVerdict.closesWindow(rawVerdict: " interactive\n"))
        XCTAssertFalse(FluxAgentVerdict.closesWindow(rawVerdict: "INTERACTIVE"))
    }

    /// A verdict nobody recognises is a bug somewhere, and the safe reading of a
    /// bug is "this window is finished" — leaving it open means one dead window
    /// per email until the desktop is unusable.
    func testUnknownVerdictStillCloses() {
        XCTAssertTrue(FluxAgentVerdict.closesWindow(rawVerdict: "kaput"))
        XCTAssertTrue(FluxAgentVerdict.closesWindow(rawVerdict: "interactiv"))
    }

    /// An empty sentinel is "not finished yet", not "unknown".
    func testEmptyVerdictClosesNothing() {
        XCTAssertFalse(FluxAgentVerdict.closesWindow(rawVerdict: ""))
        XCTAssertFalse(FluxAgentVerdict.closesWindow(rawVerdict: "\n"))
        XCTAssertNil(FluxAgentVerdict.parse(""))
    }

    // MARK: - the generated AppleScript

    private func screens() -> [TerminalWindowPlacement.ScreenBox] {
        [
            TerminalWindowPlacement.ScreenBox(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                              visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                              isBuiltin: true),
            TerminalWindowPlacement.ScreenBox(frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
                                              visibleFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
                                              isBuiltin: false),
        ]
    }

    private func script() -> String {
        FluxAgentLauncher.appleScript(script: "/tmp/flux-agent.sh",
                                      sentinel: "/tmp/flux.done",
                                      messageId: "<abc@mail.gmail.com>",
                                      threadId: "thread-1",
                                      screens: screens())
    }

    /// The literal in the AppleScript and the one `flux-agent.sh` writes are the
    /// same string, on both sides of a shell/AppleScript boundary no compiler
    /// checks. `FluxAgentVerdict` owns it; this asserts it actually reaches the
    /// generated script.
    func testScriptBranchesOnTheInteractiveVerdict() {
        XCTAssertTrue(script().contains("if verdict is \"interactive\" then"), script())
    }

    /// …and that the close branch is still there for everything else.
    func testScriptStillClosesOnOtherVerdicts() {
        let s = script()
        XCTAssertTrue(s.contains("else if verdict is not \"\" then"), s)
        XCTAssertTrue(s.contains("close (every window whose tabs contains t) saving no"), s)
    }

    /// The interactive window is a window to sit down and type in, so it gets a
    /// bigger rect than the 10%-of-the-screen glance window it opened as — and
    /// still on the external screen, never the Retina the projector mirrors.
    func testInteractiveWindowIsResizedBigger() {
        let small = TerminalWindowPlacement.bounds(screens: screens(), areaFraction: 0.10)!
        let big = TerminalWindowPlacement.bounds(screens: screens(), areaFraction: 0.45)!
        XCTAssertGreaterThan(big.right - big.left, small.right - small.left)
        XCTAssertTrue(script().contains(big.appleScriptList), script())
        XCTAssertGreaterThanOrEqual(big.left, 1728)
    }

    /// The whole point of generating AppleScript from Swift is that a syntax
    /// error in it is invisible until an email arrives at midnight. `osacompile`
    /// settles that here instead.
    func testScriptCompiles() throws {
        let compiler = "/usr/bin/osacompile"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: compiler))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: compiler)
        p.arguments = ["-o", NSTemporaryDirectory() + "flux-agent-test-\(UUID().uuidString).scpt", "-e", script()]
        let err = Pipe()
        p.standardError = err
        try p.run()
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "osacompile rejected the script: \(message)")
    }

    /// Single quotes in an id must not break out of the `do script` word.
    func testIdsAreShellEscaped() {
        let s = FluxAgentLauncher.appleScript(script: "/tmp/flux-agent.sh",
                                              sentinel: "/tmp/flux.done",
                                              messageId: "a'b",
                                              threadId: "t",
                                              screens: screens())
        XCTAssertTrue(s.contains("'a'\\''b'"), s)
    }
}
