import XCTest
@testable import VictorAddons

/// The bottom-left receipt the 🎙️ picker leaves behind (`copyBanner`).
///
/// The pill is the only thing still on screen a second after the pick — the
/// panel is gone and the pasteboard is invisible — so what it says is the
/// user's entire evidence that the row they clicked is the text they are about
/// to ⌘V. Everything here is about it staying *one readable line*.
@MainActor
final class TranscriptCopyBannerTests: XCTestCase {

    func testEchoesShortPicksWhole() {
        XCTAssertEqual(TranscriptPasteController.copyBanner(for: "Testele sunt design.", landed: true),
                       "📋 Testele sunt design.")
    }

    func testTruncatesLongPicksWithAnEllipsis() {
        let long = String(repeating: "a", count: 200)
        let banner = TranscriptPasteController.copyBanner(for: long, landed: true)
        XCTAssertTrue(banner.hasSuffix("…"))
        // 📋 + space + preview + …
        XCTAssertEqual(banner.count, TranscriptPasteController.bannerPreviewChars + 3)
    }

    func testCarriesNoQuotationMarks() {
        // The pill caps at half the screen and truncates past it, so a closing
        // `”` is the first thing to go — leaving a quote that never closes,
        // which reads as a bug rather than as a truncation.
        let banner = TranscriptPasteController.copyBanner(
            for: "Testele sunt design, nu verificare.", landed: true)
        XCTAssertFalse(banner.contains("\u{201C}"))
        XCTAssertFalse(banner.contains("\u{201D}"))
        XCTAssertFalse(banner.contains("\""))
    }

    func testNeverTruncatesMidSpace() {
        // A cut landing on a space would quote a trailing gap before the "…".
        let text = String(repeating: "ab ", count: 60)
        let banner = TranscriptPasteController.copyBanner(for: text, landed: true)
        XCTAssertFalse(banner.contains(" …"))
    }

    func testCollapsesNewlinesSoTheQuoteSurvivesTheBreak() {
        // The pill draws one line: a raw newline would simply cut the quote at
        // the break and the second half would never be seen.
        let banner = TranscriptPasteController.copyBanner(for: "prima\nа doua", landed: true)
        XCTAssertFalse(banner.contains("\n"))
        XCTAssertEqual(banner, "📋 prima а doua")
    }

    func testAFailedWriteSaysSoInsteadOfQuotingText() {
        // The whole reason the write is read back: quoting text that is NOT on
        // the pasteboard would be worse than no banner at all.
        let banner = TranscriptPasteController.copyBanner(for: "Testele sunt design.", landed: false)
        XCTAssertEqual(banner, "📋❌ clipboard write failed")
        XCTAssertFalse(banner.contains("Testele"))
    }

    func testAnEmptyPickStillProducesAWellFormedPill() {
        XCTAssertEqual(TranscriptPasteController.copyBanner(for: "", landed: true), "📋 ")
    }

    // MARK: the 60 s window

    func testTheWindowIsAFullMinuteOfSpeech() {
        // 60 s / 8 s per line = the last 8 lines. Pinned because the number was
        // walked back from 60 to 40 once already and walked back up again on
        // 2026-09-19: it is a product decision, not an implementation detail.
        let lines = TranscriptTail.parse((1...20).map { "[09:05] line \($0)" }.joined(separator: "\n"))
        let window = TranscriptTail.lastSeconds(lines, seconds: 60)
        XCTAssertEqual(window.count, 8)
        XCTAssertEqual(window.first?.text, "line 13")
        XCTAssertEqual(window.last?.text, "line 20")
    }

    // MARK: the test hook that reaches past the pick

    func testPickIsParsedOffTheTestRoute() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcript-picker?at=23:59&pick=1"),
                       .testTranscriptPicker(at: "23:59", pick: 1))
    }

    func testPickIsOptionalAndSurvivesNonsense() {
        // No `pick` is the normal, hands-on case; a `pick` that is not a number
        // must open the panel rather than refuse the whole route.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcript-picker"),
                       .testTranscriptPicker(at: nil, pick: nil))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcript-picker?pick=banana"),
                       .testTranscriptPicker(at: nil, pick: nil))
    }
}
