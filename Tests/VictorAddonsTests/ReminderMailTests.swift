import AppKit
import XCTest
@testable import VictorAddons

final class ReminderMailTests: XCTestCase {

    // MARK: Subject

    func testSubjectAlwaysStartsWithTheWordEverythingIsFiledUnder() {
        // The whole point of the prefix: `subject:Reminder` in Gmail must find
        // every one of these, whatever was on the clipboard.
        for text in [nil, "", "   ", "buy milk", "a\nb"] as [String?] {
            XCTAssertTrue(ReminderMail.subject(text: text).hasPrefix("Reminder"),
                          "subject for \(String(describing: text)) lost the prefix")
        }
    }

    func testSubjectCarriesTheFirstRealLineOfTheClipboard() {
        XCTAssertEqual(ReminderMail.subject(text: "buy milk"), "Reminder: buy milk")
        // Leading blank lines are what a copied paragraph usually starts with;
        // a subject reading "Reminder: " would be worse than none.
        XCTAssertEqual(ReminderMail.subject(text: "\n\n  hello \nworld"), "Reminder: hello")
        XCTAssertEqual(ReminderMail.subject(text: nil), "Reminder")
        XCTAssertEqual(ReminderMail.subject(text: "   "), "Reminder")
    }

    func testLongSubjectIsCutSoTheNotificationStaysReadable() {
        let long = String(repeating: "x", count: 200)
        let subject = ReminderMail.subject(text: long)
        XCTAssertTrue(subject.hasSuffix("…"))
        XCTAssertEqual(subject, "Reminder: " + String(repeating: "x", count: 60) + "…")
    }

    func testSubjectNeverContainsANewline() {
        // A raw \n in the JSON subject is a header injection in any mail system
        // that doesn't fold it; taking only the first line makes it impossible.
        XCTAssertFalse(ReminderMail.subject(text: "one\nBcc: evil@example.com").contains("\n"))
        XCTAssertEqual(ReminderMail.subject(text: "one\nBcc: evil@example.com"), "Reminder: one")
    }

    // MARK: Payload

    func testTextOnlyClippingIsSentAsPlainTextWithNoAttachment() {
        let payload = ReminderMail.payload(for: .init(text: "buy milk", image: nil))
        XCTAssertEqual(payload["to"] as? String, "victorrentea@gmail.com")
        XCTAssertEqual(payload["subject"] as? String, "Reminder: buy milk")
        XCTAssertEqual(payload["text"] as? String, "buy milk")
        XCTAssertNil(payload["attachments"])
        // No HTML part when there is nothing an HTML part could add.
        XCTAssertNil(payload["html"])
    }

    func testImageIsAttachedInlineWithSnakeCaseKeysAndACidTheHtmlReferences() {
        let image = ReminderMail.Clipping.Image(
            data: Data([1, 2, 3]), filename: "clipboard.png", contentType: "image/png")
        let payload = ReminderMail.payload(for: .init(text: nil, image: image))

        let attachments = payload["attachments"] as? [[String: Any]]
        XCTAssertEqual(attachments?.count, 1)
        let attachment = try! XCTUnwrap(attachments?.first)
        // camelCase is ignored in silence by AgentMail — assert the wire names.
        XCTAssertEqual(attachment["filename"] as? String, "clipboard.png")
        XCTAssertEqual(attachment["content_type"] as? String, "image/png")
        XCTAssertEqual(attachment["content"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(attachment["content_id"] as? String, "clipboard")
        XCTAssertEqual(attachment["content_disposition"] as? String, "inline")

        // The picture must be *in* the mail, so the html has to point at the
        // same id the attachment was given.
        let html = try! XCTUnwrap(payload["html"] as? String)
        XCTAssertTrue(html.contains("cid:clipboard"))
    }

    func testAnImageOnlyReminderStillHasAPlainTextPart() {
        // Some clients render the text/plain part; an empty one looks like a
        // mail that failed rather than a picture that arrived.
        let image = ReminderMail.Clipping.Image(
            data: Data([1]), filename: "clipboard.png", contentType: "image/png")
        let payload = ReminderMail.payload(for: .init(text: nil, image: image))
        XCTAssertEqual(payload["text"] as? String, ReminderMail.imageOnlyBody)
        XCTAssertEqual(payload["subject"] as? String, "Reminder")
    }

    func testTextAndImageTogetherKeepBothHalves() {
        let image = ReminderMail.Clipping.Image(
            data: Data([1]), filename: "clipboard.png", contentType: "image/png")
        let payload = ReminderMail.payload(for: .init(text: "see this", image: image))
        XCTAssertEqual(payload["text"] as? String, "see this")
        let html = try! XCTUnwrap(payload["html"] as? String)
        XCTAssertTrue(html.contains("see this"))
        XCTAssertTrue(html.contains("cid:clipboard"))
        XCTAssertNotNil(payload["attachments"])
    }

    func testClipboardMarkupCannotEscapeIntoTheHtmlBody() {
        let image = ReminderMail.Clipping.Image(
            data: Data([1]), filename: "clipboard.png", contentType: "image/png")
        let payload = ReminderMail.payload(for: .init(text: "<script>x</script> a & b",
                                                     image: image))
        let html = try! XCTUnwrap(payload["html"] as? String)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("a &amp; b"))
    }

    func testPayloadIsAlwaysSerialisableEvenWithHostileClipboardText() {
        // Built as a dictionary, not by interpolation: quotes and backslashes
        // in the clipboard must not be able to reshape the request.
        let clip = ReminderMail.Clipping(text: "\"}, \"bcc\": \"evil@example.com\", \"x\": \"\\",
                                         image: nil)
        let data = try! JSONSerialization.data(withJSONObject: ReminderMail.payload(for: clip))
        let back = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(back["bcc"])
        XCTAssertEqual(back["to"] as? String, "victorrentea@gmail.com")
    }

    func testAVeryLongClipboardIsTruncatedRatherThanRefused() {
        let clip = ReminderMail.Clipping(text: String(repeating: "y", count: 500_000), image: nil)
        let text = try! XCTUnwrap(ReminderMail.payload(for: clip)["text"] as? String)
        XCTAssertLessThanOrEqual(text.count, ReminderMail.textLimit + 2)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    // MARK: Resolving the clipboard

    func testEmptyClipboardIsRecognisedSoNothingIsMailed() {
        XCTAssertTrue(ReminderMail.clipping(from: .init()).isEmpty)
        XCTAssertTrue(ReminderMail.clipping(from: .init(text: "   ")).isEmpty)
        XCTAssertFalse(ReminderMail.clipping(from: .init(text: "hi")).isEmpty)
    }

    func testWhitespaceOnlyClipboardTextIsDroppedNotSentAsABlankReminder() {
        XCTAssertNil(ReminderMail.clipping(from: .init(text: "\n \t ")).text)
        XCTAssertEqual(ReminderMail.clipping(from: .init(text: "  hi  ")).text, "hi")
    }

    func testPngOnThePasteboardIsPreferredOverTiff() {
        let clip = ReminderMail.clipping(from: .init(png: Data([9, 9]), tiff: Data([1, 1])))
        XCTAssertEqual(clip.image?.data, Data([9, 9]))
        XCTAssertEqual(clip.image?.contentType, "image/png")
    }

    func testTiffOnlyPasteboardIsReencodedToPng() throws {
        // What most apps leave when you copy a picture — it must not be mailed
        // as raw TIFF, which several mail clients refuse to show inline.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let tiff = try XCTUnwrap(rep.representation(using: .tiff, properties: [:]))

        let clip = ReminderMail.clipping(from: .init(tiff: tiff))
        let image = try XCTUnwrap(clip.image)
        XCTAssertEqual(image.contentType, "image/png")
        XCTAssertEqual(image.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))  // \x89PNG
    }

    func testAnImageFileCopiedInFinderIsReadFromDiskAndMailed() {
        // Finder puts a URL on the pasteboard, not pixels — without this branch
        // "copy the picture, press ⌘⌃P" would mail its path as text.
        let url = URL(fileURLWithPath: "/tmp/holiday.JPG")
        let clip = ReminderMail.clipping(from: .init(fileURLs: [url]),
                                         readData: { _ in Data([7, 7, 7]) })
        XCTAssertEqual(clip.image?.data, Data([7, 7, 7]))
        XCTAssertEqual(clip.image?.filename, "holiday.JPG")
        XCTAssertEqual(clip.image?.contentType, "image/jpeg")
    }

    func testTheFileUrlItselfIsNotAlsoSentAsTheBody() {
        let url = URL(fileURLWithPath: "/tmp/holiday.png")
        for duplicate in [url.path, url.absoluteString, url.lastPathComponent] {
            let clip = ReminderMail.clipping(from: .init(text: duplicate, fileURLs: [url]),
                                             readData: { _ in Data([1]) })
            XCTAssertNil(clip.text, "'\(duplicate)' should not be repeated as the body")
            XCTAssertNotNil(clip.image)
        }
    }

    func testANoteCopiedAlongsideAnImageFileSurvives() {
        let url = URL(fileURLWithPath: "/tmp/holiday.png")
        let clip = ReminderMail.clipping(from: .init(text: "ask about this", fileURLs: [url]),
                                         readData: { _ in Data([1]) })
        XCTAssertEqual(clip.text, "ask about this")
    }

    func testNonImageFilesAreIgnored() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let clip = ReminderMail.clipping(from: .init(fileURLs: [url]),
                                         readData: { _ in Data([1]) })
        XCTAssertNil(clip.image)
        XCTAssertTrue(clip.isEmpty)
    }

    func testUnreadableFileUrlDoesNotProduceAnEmptyAttachment() {
        let url = URL(fileURLWithPath: "/tmp/gone.png")
        let clip = ReminderMail.clipping(from: .init(text: "note", fileURLs: [url]),
                                         readData: { _ in nil })
        XCTAssertNil(clip.image)
        XCTAssertEqual(clip.text, "note")
    }

    // MARK: Size

    func testAnImageAlreadyUnderTheLimitIsLeftExactlyAsCopied() {
        let image = ReminderMail.Clipping.Image(
            data: Data([1, 2, 3]), filename: "clipboard.png", contentType: "image/png")
        XCTAssertEqual(ReminderMail.fit(image), image)
    }

    func testAnOversizedScreenshotIsReencodedToFitTheRequestLimit() throws {
        // A retina full-screen PNG is several MB; AgentMail caps the whole
        // request at 6 MB and base64 adds a third on top.
        let height = 1200
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // Deterministic noise written straight into the buffer: a gradient or a
        // flat fill compresses to almost nothing, and a fixture that slips under
        // the budget would make this test pass without ever shrinking anything.
        let pixels = try XCTUnwrap(rep.bitmapData)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for i in 0..<(rep.bytesPerRow * height) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            pixels[i] = UInt8(truncatingIfNeeded: seed)
        }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, ReminderMail.maxAttachmentBytes,
                             "fixture must actually exceed the budget for this test to mean anything")

        let fitted = ReminderMail.fit(.init(data: png, filename: "clipboard.png",
                                            contentType: "image/png"))
        XCTAssertLessThanOrEqual(fitted.data.count, ReminderMail.maxAttachmentBytes)
        XCTAssertEqual(fitted.contentType, "image/jpeg")
        XCTAssertEqual(fitted.filename, "clipboard.jpg")
    }

    // MARK: Banner

    func testTheBannerNamesWhatActuallyLeftTheMac() {
        let image = ReminderMail.Clipping.Image(
            data: Data([1]), filename: "a.png", contentType: "image/png")
        XCTAssertEqual(ReminderMail.confirmation(for: .init(text: "x", image: image)),
                       "📤 Reminder trimis (imagine + text)")
        XCTAssertEqual(ReminderMail.confirmation(for: .init(text: nil, image: image)),
                       "📤 Reminder trimis (imagine)")
        XCTAssertEqual(ReminderMail.confirmation(for: .init(text: "x", image: nil)),
                       "📤 Reminder trimis")
    }

    func testAnEmptyClipboardFailsBeforeAnyRequestIsMade() {
        // The guard lives in `send`, not at the call site, so no caller — the
        // key, the HTTP hook, or a later one — can mail a blank Reminder. It
        // must also answer synchronously: a session configured to refuse every
        // request proves nothing was attempted.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefuseEverything.self]
        let mailer = ReminderMailer(apiKey: "unused", session: URLSession(configuration: config))

        var outcome: Result<Void, Error>?
        mailer.send(.init(text: nil, image: nil)) { outcome = $0 }

        guard case .failure(let error)? = outcome else {
            return XCTFail("an empty clipboard must not be mailed")
        }
        XCTAssertEqual(error as? ReminderMailer.SendError, .emptyClipboard)
        XCTAssertEqual(RefuseEverything.requests, 0, "no HTTP request should have been built")
    }
}

/// Fails any request that reaches it, and counts them — so "nothing was sent"
/// can be asserted rather than assumed from a callback that merely fired fast.
private final class RefuseEverything: URLProtocol {
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { requests += 1; return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
