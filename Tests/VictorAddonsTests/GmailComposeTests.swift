import XCTest
@testable import VictorAddons

final class GmailComposeTests: XCTestCase {

    func testDraftCarriesRecipientSubjectAndBody() {
        let draft = GmailCompose.draft(clipboard: "buy milk", to: "victorrentea@gmail.com")
        XCTAssertFalse(draft.truncated)
        XCTAssertTrue(draft.url.hasPrefix("https://mail.google.com/mail/?view=cm&fs=1"))
        XCTAssertTrue(draft.url.contains("&to=victorrentea%40gmail.com"))
        XCTAssertTrue(draft.url.contains("&su=TO%20DO"))
        XCTAssertTrue(draft.url.hasSuffix("&body=buy%20milk"))
    }

    /// A `&` or `=` left raw in the body would end the parameter early and the
    /// rest of the note would arrive as junk query parameters instead of text.
    func testQuerySyntaxInsideTheClipboardIsEncoded() {
        let url = GmailCompose.draft(clipboard: "a&b=c#d+e").url
        XCTAssertTrue(url.hasSuffix("&body=a%26b%3Dc%23d%2Be"), url)
    }

    func testNewlinesSurviveAsEncodedLineBreaks() {
        let url = GmailCompose.draft(clipboard: "one\ntwo").url
        XCTAssertTrue(url.hasSuffix("&body=one%0Atwo"), url)
    }

    func testEmptyClipboardStillOpensAnEmptyDraft() {
        let draft = GmailCompose.draft(clipboard: "")
        XCTAssertFalse(draft.truncated)
        XCTAssertTrue(draft.url.hasSuffix("&body="))
    }

    func testDiacriticsAreEncodedNotDropped() {
        let url = GmailCompose.draft(clipboard: "ă").url
        XCTAssertTrue(url.hasSuffix("&body=%C4%83"), url)
    }

    func testOverlongClipboardIsCutToFitAndSaysSo() {
        let draft = GmailCompose.draft(clipboard: String(repeating: "x", count: 50_000))
        XCTAssertTrue(draft.truncated)
        XCTAssertLessThanOrEqual(draft.url.count, GmailCompose.maxURLLength)
        XCTAssertTrue(draft.url.hasSuffix(GmailCompose.encode(GmailCompose.truncationNotice)))
    }

    /// Worst case for the budget maths: every character encodes to 9 characters,
    /// so a naive "cut one at a time" loop would take tens of thousands of passes
    /// and a naive byte count would overshoot the limit.
    func testOverlongMultiByteClipboardAlsoFits() {
        let draft = GmailCompose.draft(clipboard: String(repeating: "🙂", count: 5_000))
        XCTAssertTrue(draft.truncated)
        XCTAssertLessThanOrEqual(draft.url.count, GmailCompose.maxURLLength)
    }

    /// A clipboard just under the limit must be sent whole — the notice is only
    /// for text that genuinely didn't fit.
    func testClipboardThatExactlyFitsIsNotTruncated() {
        let prefixLength = GmailCompose.draft(clipboard: "").url.count
        let body = String(repeating: "y", count: GmailCompose.maxURLLength - prefixLength)
        let draft = GmailCompose.draft(clipboard: body)
        XCTAssertFalse(draft.truncated)
        XCTAssertEqual(draft.url.count, GmailCompose.maxURLLength)
    }

    func testFitEncodedReturnsAPrefixOfTheOriginal() {
        let text = "abcdefghij"
        let kept = GmailCompose.fitEncoded(text, budget: 4)
        XCTAssertEqual(kept, "abcd")
        XCTAssertEqual(GmailCompose.fitEncoded(text, budget: 0), "")
        XCTAssertEqual(GmailCompose.fitEncoded(text, budget: -5), "")
    }
}
