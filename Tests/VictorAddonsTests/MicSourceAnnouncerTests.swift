import XCTest
@testable import VictorAddons

/// The pill names what Whisper records through, from `VICTOR_SOURCE:`'s glyph,
/// and never for the launch baseline (2026-09-23).
final class MicSourceAnnouncerTests: XCTestCase {

    func testTheCopyIsTheRosterGlyphAndLabel() {
        XCTAssertEqual(MicSourceAnnouncer.cardText(glyph: "🎤"), "🎤 Listening to: DJI")
        XCTAssertEqual(MicSourceAnnouncer.cardText(glyph: "💻"), "💻 Listening to: MacBook Pro Microphone")
    }

    func testAnUnknownGlyphIsShownAsTheRawName() {
        XCTAssertEqual(MicSourceAnnouncer.cardText(glyph: "Loopback Audio"), "🎙️ Listening to: Loopback Audio")
    }

    func testTheBaselineIsSilentAndAChangeIsAnnouncedOnce() {
        var shown: [String] = []
        let a = MicSourceAnnouncer(show: { shown.append($0) })
        a.sourceChanged("🎤")                       // baseline
        a.sourceChanged("💻")
        a.sourceChanged("💻")
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + MicSourceAnnouncer.settle + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(shown, ["💻 Listening to: MacBook Pro Microphone"])
    }

    func testABurstThatEndsWhereItBeganSaysNothing() {
        var shown: [String] = []
        let a = MicSourceAnnouncer(show: { shown.append($0) })
        a.sourceChanged("🎤")
        a.sourceChanged("💻")
        a.sourceChanged("🎤")
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + MicSourceAnnouncer.settle + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(shown, [])
    }
}
