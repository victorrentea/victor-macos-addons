import XCTest
@testable import VictorAddons

/// **The microphone roster exists three times and must stay one list.**
///
/// `MicRoster` (this app's menu), `_ME_PATTERNS` + `_DEVICE_SHORT_NAMES` in
/// `whisper-transcribe/whisper_runner.py` (the process that actually opens the
/// device), and `InputDevice.known` in the `walkie-talkie` repo beside this one
/// (the same six rows in the relay's own menu). Nothing can merge them —
/// the resolver is Python, and Walkie Talkie is a public repo that must not
/// depend on this private one — so a test reads the other two and fails when
/// they drift.
///
/// The walkie-talkie half is skipped, not failed, when that checkout is not
/// beside this one: `Package.swift` already requires `../victor-mac-kit`, but a
/// missing sibling should read as *not checked out here* rather than as a
/// regression.
final class MicRosterTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)            // …/Tests/VictorAddonsTests/MicRosterTests.swift
            .deletingLastPathComponent()           // …/Tests/VictorAddonsTests
            .deletingLastPathComponent()           // …/Tests
            .deletingLastPathComponent()           // …/victor-macos-addons
    }

    private func source(_ relativePath: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Everything inside the first `[ … ]` after `name`, split on commas and
    /// stripped of quotes — enough for a flat list literal in either language.
    private func listLiteral(named name: String, in text: String) -> [String]? {
        guard let start = text.range(of: name),
              let open = text.range(of: "[", range: start.upperBound..<text.endIndex),
              let close = text.range(of: "]", range: open.upperBound..<text.endIndex)
        else { return nil }
        return text[open.upperBound..<close.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t\"")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Python

    func testThePythonLadderIsTheSameLadderInTheSameOrder() throws {
        let runner = try source("whisper-transcribe/whisper_runner.py", in: repoRoot)
        let patterns = listLiteral(named: "_ME_PATTERNS =", in: runner)
        XCTAssertEqual(patterns, MicRoster.all.map(\.pattern),
                       "whisper_runner.py's _ME_PATTERNS drifted from MicRoster.all — "
                       + "the menu's order IS the automatic ladder, so they cannot differ")
    }

    func testEveryRosterGlyphIsTheOnePythonEmits() throws {
        let runner = try source("whisper-transcribe/whisper_runner.py", in: repoRoot)
        guard let dict = runner.range(of: "_DEVICE_SHORT_NAMES = {"),
              let close = runner.range(of: "}", range: dict.upperBound..<runner.endIndex)
        else { return XCTFail("could not find _DEVICE_SHORT_NAMES in whisper_runner.py") }
        let body = String(runner[dict.upperBound..<close.lowerBound])

        for mic in MicRoster.all {
            // Python matches the *lowercased* device name against these keys,
            // and the pattern is a substring of the device name, so the key is
            // the pattern lowercased — except where Python is deliberately
            // looser (`speakerphone` for `Room Speakerphone`).
            let needle = mic.pattern.lowercased()
            let key = body
                .split(separator: "\n")
                .first { line in
                    guard let quoted = line.split(separator: "\"").dropFirst().first else { return false }
                    return needle.contains(quoted) || quoted.contains(needle)
                }
            XCTAssertNotNil(key, "no _DEVICE_SHORT_NAMES entry matches '\(mic.pattern)'")
            XCTAssertTrue(key?.contains(mic.glyph) ?? false,
                          "whisper_runner.py emits a different glyph for '\(mic.pattern)' "
                          + "than MicRoster's \(mic.glyph)")
        }
    }

    // MARK: - Walkie Talkie

    func testWalkieTalkieShowsTheSameRowsInTheSameOrder() throws {
        let sibling = repoRoot.deletingLastPathComponent()
            .appendingPathComponent("walkie-talkie/Sources/WalkieTalkie/InputDevice.swift")
        guard let text = try? String(contentsOf: sibling, encoding: .utf8) else {
            throw XCTSkip("walkie-talkie is not checked out beside this repo")
        }
        // `Known(id: "xlr",  glyph: "🎙️", short: "XLR", label: "Elgato Wave XLR",`
        let rows = text.split(separator: "\n").compactMap { line -> (String, String, String)? in
            guard line.contains("Known(id:") else { return nil }
            let quoted = line.split(separator: "\"").enumerated()
                .filter { $0.offset % 2 == 1 }.map { String($0.element) }
            guard quoted.count >= 3 else { return nil }
            return (quoted[0], quoted[1], quoted[2])   // id, glyph, short
        }
        XCTAssertEqual(rows.map(\.0), MicRoster.all.map(\.id),
                       "the relay's mic list drifted from this app's — the two menus "
                       + "are meant to be the same menu, and the ids are the contract "
                       + "in ~/.walkie-talkie/mic/choice")
        XCTAssertEqual(rows.map(\.1), MicRoster.all.map(\.glyph))
    }

    // MARK: - The file contract

    func testTheSharedChoiceFileLivesInWalkieTalkiesHome() {
        XCTAssertTrue(MicPreference.url.path.hasSuffix("/.walkie-talkie/mic/choice"),
                      "both apps agree on this exact path; changing it silently unsyncs them")
    }

    func testAnUnknownIdReadsAsAutomatic() {
        XCTAssertFalse(MicRoster.ids.contains(MicPreference.automatic))
        XCTAssertNil(MicRoster.byId("something-the-relay-learnt-first"))
    }

    func testTheLadderRowNamesEveryDeviceInOrder() {
        XCTAssertEqual(MicRoster.ladder, "🎙️ ▸ 🎤 ▸ 🏛️ ▸ 🎧 ▸ 💻")
    }

    func testTheDjiIsTheReceiverAloneDrawnAsAStageMic() {
        // 2026-09-23, Victor: the transmitter is never paired directly again (it
        // fights the JBL for Bluetooth); the receiver is the DJI, and it is 🎤.
        XCTAssertNil(MicRoster.byId("tx"))
        XCTAssertEqual(MicRoster.byId("rx")?.glyph, "🎤")
        XCTAssertFalse(MicRoster.all.contains { $0.glyph == "📡" })
    }

    // MARK: - Never the WH-1000XM3

    func testTheSonyHeadphonesAreNeverRecordedThrough() {
        XCTAssertTrue(MicRoster.isNeverRecord("WH-1000XM3"))
        XCTAssertTrue(MicRoster.isNeverRecord("wh-1000xm4"))
        XCTAssertFalse(MicRoster.isNeverRecord("Wireless Mic Rx"))
        XCTAssertFalse(MicRoster.isNeverRecord("MacBook Pro Microphone"))
        XCTAssertFalse(MicRoster.all.contains { MicRoster.isNeverRecord($0.pattern) },
                       "no ladder rung may match a device that is never recorded through")
    }

    func testThePythonBlocklistIsTheSameList() throws {
        let runner = try source("whisper-transcribe/whisper_runner.py", in: repoRoot)
        XCTAssertEqual(listLiteral(named: "_NEVER_RECORD =", in: runner), MicRoster.neverRecord,
                       "whisper_runner.py's _NEVER_RECORD drifted from MicRoster.neverRecord")
    }
}
