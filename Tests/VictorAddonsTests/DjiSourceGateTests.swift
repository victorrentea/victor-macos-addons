import XCTest
@testable import VictorAddons

/// The DJI is a microphone only while a transmitter is linked to the receiver.
final class DjiSourceGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let none = DjiReceiverProtocol.Status(linkedMask: 0, transmitters: [])
    private func tx(charging: Bool = false) -> DjiReceiverProtocol.Status {
        .init(linkedMask: 0x02, transmitters: [.init(unit: 2, level: 2, charging: charging)])
    }

    func testReceiverAloneIsNotASource() {
        var g = DjiSourceGate()
        XCTAssertEqual(g.feed(none, now: t0), .noTx)
        XCTAssertEqual(g.feed(none, now: t0 + 60), .noTx)
    }

    func testTransmitterOnMakesItASource() {
        var g = DjiSourceGate()
        XCTAssertEqual(g.feed(none, now: t0), .noTx)
        XCTAssertEqual(g.feed(tx(), now: t0 + 1), .linked)
    }

    func testARadioHiccupDoesNotBounceTheSource() {
        var g = DjiSourceGate()
        _ = g.feed(tx(), now: t0)
        XCTAssertEqual(g.feed(none, now: t0 + 1), .linked)
        XCTAssertEqual(g.feed(none, now: t0 + 4.9), .linked)
        XCTAssertEqual(g.feed(tx(), now: t0 + 5.5), .linked)
    }

    func testATransmitterGoneForTheGraceStopsBeingASource() {
        var g = DjiSourceGate()
        _ = g.feed(tx(), now: t0)
        _ = g.feed(none, now: t0 + 1)
        XCTAssertEqual(g.feed(none, now: t0 + 1 + DjiReceiverPolicy.linkLossGrace), .noTx)
        XCTAssertEqual(g.feed(none, now: t0 + 30), .noTx)
    }

    func testPutBackInItsCaseGoesAtOnce() {
        var g = DjiSourceGate()
        _ = g.feed(tx(charging: true), now: t0)
        XCTAssertEqual(g.feed(none, now: t0 + 0.1), .noTx)
    }

    func testResetForgetsTheLink() {
        var g = DjiSourceGate()
        _ = g.feed(tx(), now: t0)
        g.reset()
        XCTAssertEqual(g.feed(none, now: t0 + 1), .noTx, "replugged with no TX: no grace owed")
    }
}
