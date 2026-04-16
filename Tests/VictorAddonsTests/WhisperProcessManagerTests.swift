import XCTest
@testable import VictorAddons

final class WhisperProcessManagerTests: XCTestCase {
    func testWhisperScriptCandidatesIncludeConfiguredRoots() {
        let candidates = WhisperProcessManager.whisperScriptCandidates(
            binaryDir: "/Applications/Victor Addons.app/Contents/MacOS",
            envRoot: "/tmp/repo",
            homeDirectory: "/Users/victor",
            cwd: "/"
        )

        XCTAssertTrue(candidates.contains("/tmp/repo/whisper-transcribe/whisper_runner.py"))
        XCTAssertTrue(candidates.contains("/Users/victor/workspace/victor-macos-addons/whisper-transcribe/whisper_runner.py"))
    }

    func testWhisperScriptCandidatesIncludeCwdFallback() {
        let candidates = WhisperProcessManager.whisperScriptCandidates(
            binaryDir: "/bin",
            envRoot: "",
            homeDirectory: "/Users/victor",
            cwd: "/work"
        )

        XCTAssertEqual(candidates.last, "/work/whisper-transcribe/whisper_runner.py")
    }

    func testParsePIDsParsesWhitespaceSeparatedRows() {
        let output = "123\n  456\n\n789\n"
        XCTAssertEqual(WhisperProcessManager.parsePIDs(from: output), [123, 456, 789])
    }

    func testParsePIDsIgnoresInvalidRows() {
        let output = "abc\n42x\n17\n"
        XCTAssertEqual(WhisperProcessManager.parsePIDs(from: output), [17])
    }
}
