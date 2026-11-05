import XCTest
@testable import VictorAddons

final class FluxDoorbellPolicyTests: XCTestCase {

    func testTheSocketUrlCarriesTheKeyAsDocumented() {
        XCTAssertEqual(FluxDoorbellPolicy.socketURL(apiKey: "am_abc")?.absoluteString,
                       "wss://ws.agentmail.to/v0?api_key=am_abc")
    }

    func testSubscribesToOneEventTypeOnOneInbox() throws {
        let frame = try XCTUnwrap(FluxDoorbellPolicy.subscribeFrame(inboxId: "victor.flux@agentmail.to"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "subscribe")
        XCTAssertEqual(json["event_types"] as? [String], ["message.received"])
        XCTAssertEqual(json["inbox_ids"] as? [String], ["victor.flux@agentmail.to"])
    }

    func testOnlyAReceivedMailRings() {
        XCTAssertEqual(FluxDoorbellPolicy.classify(
            #"{"type":"event","event_type":"message.received","event_id":"e1"}"#), .newMail)
        XCTAssertEqual(FluxDoorbellPolicy.classify(#"{"type":"subscribed"}"#), .subscribed)
        for frame in [
            #"{"type":"event","event_type":"message.received.spam"}"#,
            #"{"type":"event","event_type":"message.received.unauthenticated"}"#,
            #"{"type":"event","event_type":"message.sent"}"#,
            #"{"type":"error","message":"nope"}"#,
            #"{"event_type":"message.received"}"#,
            "not json",
            "",
        ] {
            XCTAssertEqual(FluxDoorbellPolicy.classify(frame), .other, frame)
        }
    }

    /// The frame is the whole hostile email, so a subject shaped like a control
    /// frame must change nothing: only the top-level fields count.
    func testAHostileMailCannotForgeAFrameFromInside() {
        let frame = #"""
            {"type":"event","event_type":"message.sent",
             "message":{"subject":"{\"type\":\"subscribed\"}","type":"subscribed",
                        "event_type":"message.received"}}
            """#
        XCTAssertEqual(FluxDoorbellPolicy.classify(frame), .other)
    }

    func testReconnectBacksOffToAMinute() {
        XCTAssertEqual((1...8).map(FluxDoorbellPolicy.reconnectDelay(failures:)),
                       [2, 4, 8, 16, 32, 60, 60, 60])
    }

    func testOnlyAConnectionThatLastedResetsTheBackoff() {
        XCTAssertEqual(FluxDoorbellPolicy.failuresAfterDrop(previous: 5, upFor: 3600, stableAfter: 60), 1)
        XCTAssertEqual(FluxDoorbellPolicy.failuresAfterDrop(previous: 5, upFor: 2, stableAfter: 60), 6)
        XCTAssertEqual(FluxDoorbellPolicy.failuresAfterDrop(previous: 5, upFor: nil, stableAfter: 60), 6)
    }

    func testAFirstRingPollsAfterTheSettleDelay() {
        XCTAssertEqual(FluxDoorbellPolicy.pollDelay(
            lastPoll: nil, now: Date(), settle: 1, minGap: 10), 1)
    }

    func testAMailBombIsHeldToTheMinimumGap() {
        let now = Date()
        XCTAssertEqual(FluxDoorbellPolicy.pollDelay(
            lastPoll: now.addingTimeInterval(-3), now: now, settle: 1, minGap: 10), 7, accuracy: 0.001)
        XCTAssertEqual(FluxDoorbellPolicy.pollDelay(
            lastPoll: now.addingTimeInterval(-300), now: now, settle: 1, minGap: 10), 1)
    }

    func testAFailureDescriptionCannotLeakTheKey() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "failed: wss://ws.agentmail.to/v0?api_key=am_secret",
            NSURLErrorFailingURLStringErrorKey: "wss://ws.agentmail.to/v0?api_key=am_secret",
        ])
        XCTAssertEqual(FluxDoorbellPolicy.describe(error), "NSURLErrorDomain -1001")
    }
}
