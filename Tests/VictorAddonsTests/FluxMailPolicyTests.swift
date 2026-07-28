import XCTest
@testable import VictorAddons

/// The Flux inbox is a public address, so these tests are the security boundary:
/// they pin down exactly which mail is allowed to trigger anything.
final class FluxMailPolicyTests: XCTestCase {

    /// A real `Authentication-Results` stamp for mail genuinely sent by Victor,
    /// copied from the live inbox.
    private let goodAuth = """
        amazonses.com; spf=pass (spfCheck: domain of _spf.google.com designates \
        209.85.208.48 as permitted sender) client-ip=209.85.208.48; \
        envelope-from=victorrentea@gmail.com; helo=mail-ed1-f48.google.com; \
        dkim=pass header.i=@gmail.com; dmarc=pass header.from=gmail.com;
        """

    private func message(from: String,
                         auth: String? = nil,
                         id: String = "m1",
                         at: Date = Date(timeIntervalSince1970: 1_000)) -> FluxMessage {
        FluxMessage(messageId: id, from: from, subject: "hi", timestamp: at,
                    authenticationResults: auth ?? goodAuth)
    }

    // MARK: Address extraction

    func testExtractsAddressFromDisplayNameForm() {
        XCTAssertEqual(
            FluxMailPolicy.address(fromHeader: "Victor Rentea <victorrentea@gmail.com>"),
            "victorrentea@gmail.com")
    }

    func testExtractsBareAddress() {
        XCTAssertEqual(
            FluxMailPolicy.address(fromHeader: "victorrentea@gmail.com"),
            "victorrentea@gmail.com")
    }

    func testAddressIsCaseInsensitive() {
        XCTAssertEqual(
            FluxMailPolicy.address(fromHeader: "Victor <VictorRentea@Gmail.COM>"),
            "victorrentea@gmail.com")
    }

    /// The real address lives in the *last* angle-bracket group; a display name
    /// that merely looks like Victor's address must not win.
    func testDisplayNameSpoofIsRejected() {
        let spoof = "victorrentea@gmail.com <attacker@evil.com>"
        XCTAssertEqual(FluxMailPolicy.address(fromHeader: spoof), "attacker@evil.com")
        XCTAssertFalse(FluxMailPolicy.isTrustedAddress(spoof))
    }

    // MARK: Exact-match gate — the substring traps

    func testSubdomainSuffixIsRejected() {
        XCTAssertFalse(
            FluxMailPolicy.isTrustedAddress("Victor <victorrentea@gmail.com.evil.com>"))
    }

    func testPrefixedLocalPartIsRejected() {
        XCTAssertFalse(
            FluxMailPolicy.isTrustedAddress("Not Victor <notvictorrentea@gmail.com>"))
    }

    func testSuffixedLocalPartIsRejected() {
        XCTAssertFalse(
            FluxMailPolicy.isTrustedAddress("<victorrentea@gmail.com.co>"))
    }

    func testPlusAddressingIsRejected() {
        XCTAssertFalse(
            FluxMailPolicy.isTrustedAddress("<victorrentea+x@gmail.com>"))
    }

    func testDifferentSenderIsRejected() {
        XCTAssertFalse(FluxMailPolicy.isTrustedAddress("<someone@else.com>"))
    }

    func testGenuineSenderIsAccepted() {
        XCTAssertTrue(
            FluxMailPolicy.isTrustedAddress("Victor Rentea <victorrentea@gmail.com>"))
    }

    // MARK: Authentication gate

    func testRealGmailStampPasses() {
        XCTAssertTrue(FluxMailPolicy.isAuthenticated(goodAuth))
    }

    func testMissingAuthHeaderFailsClosed() {
        XCTAssertFalse(FluxMailPolicy.isAuthenticated(nil))
    }

    func testDkimFailureIsRejected() {
        let auth = "amazonses.com; dkim=fail header.i=@gmail.com; dmarc=pass header.from=gmail.com;"
        XCTAssertFalse(FluxMailPolicy.isAuthenticated(auth))
    }

    func testDmarcFailureIsRejected() {
        let auth = "amazonses.com; dkim=pass header.i=@gmail.com; dmarc=fail header.from=gmail.com;"
        XCTAssertFalse(FluxMailPolicy.isAuthenticated(auth))
    }

    /// DKIM signed by some other domain must not satisfy the gmail.com gate.
    func testForeignSigningDomainIsRejected() {
        let auth = "amazonses.com; dkim=pass header.i=@evil.com; dmarc=pass header.from=evil.com;"
        XCTAssertFalse(FluxMailPolicy.isAuthenticated(auth))
    }

    // MARK: Both gates together

    /// The address is Victor's, but nothing verified it — reject.
    func testCorrectAddressWithoutAuthenticationIsRejected() {
        let msg = message(from: "Victor <victorrentea@gmail.com>", auth: "amazonses.com; dkim=none;")
        XCTAssertFalse(FluxMailPolicy.isTrusted(msg))
    }

    /// Authentication passes for gmail.com, but the sender is a different gmail
    /// user — reject. This is why the address gate cannot be dropped.
    func testOtherGmailUserIsRejected() {
        let msg = message(from: "Someone <someone.else@gmail.com>")
        XCTAssertFalse(FluxMailPolicy.isTrusted(msg))
    }

    func testGenuineVictorMailIsTrusted() {
        XCTAssertTrue(FluxMailPolicy.isTrusted(message(from: "Victor Rentea <victorrentea@gmail.com>")))
    }

    // MARK: Watermark / dedupe

    private let epoch = Date(timeIntervalSince1970: 1_000)
    private let victor = "Victor Rentea <victorrentea@gmail.com>"

    func testOlderMailIsNotReported() {
        let old = message(from: victor, at: epoch.addingTimeInterval(-60))
        XCTAssertTrue(FluxMailPolicy.newMail(in: [old], since: epoch, seen: []).isEmpty)
    }

    func testNewerMailIsReported() {
        let fresh = message(from: victor, at: epoch.addingTimeInterval(60))
        XCTAssertEqual(FluxMailPolicy.newMail(in: [fresh], since: epoch, seen: []).count, 1)
    }

    func testMailExactlyAtWatermarkIsNotReplayed() {
        let same = message(from: victor, at: epoch)
        XCTAssertTrue(FluxMailPolicy.newMail(in: [same], since: epoch, seen: []).isEmpty)
    }

    func testAlreadySeenIdIsNotReported() {
        let fresh = message(from: victor, id: "seen-1", at: epoch.addingTimeInterval(60))
        XCTAssertTrue(FluxMailPolicy.newMail(in: [fresh], since: epoch, seen: ["seen-1"]).isEmpty)
    }

    func testUntrustedNewMailIsFilteredOut() {
        let attacker = message(from: "<attacker@evil.com>", at: epoch.addingTimeInterval(60))
        XCTAssertTrue(FluxMailPolicy.newMail(in: [attacker], since: epoch, seen: []).isEmpty)
    }

    func testReportedOldestFirst() {
        let a = message(from: victor, id: "a", at: epoch.addingTimeInterval(30))
        let b = message(from: victor, id: "b", at: epoch.addingTimeInterval(60))
        let result = FluxMailPolicy.newMail(in: [b, a], since: epoch, seen: [])
        XCTAssertEqual(result.map(\.messageId), ["a", "b"])
    }

    // MARK: Response parsing

    func testParsesLiveResponseShape() {
        let json = """
        {"count":1,"messages":[{
          "message_id":"<abc@mail.gmail.com>",
          "from":"Victor Rentea <victorrentea@gmail.com>",
          "subject":"Export PDF",
          "timestamp":"2026-06-01T18:56:33.000Z",
          "headers":{"Authentication-Results":"amazonses.com; dkim=pass header.i=@gmail.com;"}
        }]}
        """.data(using: .utf8)!
        let parsed = FluxInboxPoller.parse(json)
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.messageId, "<abc@mail.gmail.com>")
        XCTAssertEqual(parsed?.first?.subject, "Export PDF")
        XCTAssertNotNil(parsed?.first?.authenticationResults)
    }

    func testParsesTimestampWithoutFractionalSeconds() {
        let json = """
        {"messages":[{"message_id":"x","from":"a@b.com",
          "timestamp":"2026-06-01T18:56:33Z","headers":{}}]}
        """.data(using: .utf8)!
        XCTAssertEqual(FluxInboxPoller.parse(json)?.count, 1)
    }

    func testMalformedResponseIsRejected() {
        XCTAssertNil(FluxInboxPoller.parse("not json".data(using: .utf8)!))
    }
}
