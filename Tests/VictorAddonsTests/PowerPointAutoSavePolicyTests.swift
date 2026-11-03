import XCTest
@testable import VictorAddons

final class PowerPointAutoSavePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let deck = "/d/a.pptx"

    private func s(_ sec: Double, saved: Bool = false, path: String? = "/d/a.pptx",
                   presenting: Bool = false) -> PowerPointSample {
        PowerPointSample(at: t0.addingTimeInterval(sec), deck: "a.pptx", path: path, slide: 1,
                         slideID: 256, presenting: presenting, frontmost: true, saved: saved)
    }

    func testSavesAfterAMinuteUnsaved() {
        var p = PowerPointAutoSavePolicy()
        XCTAssertNil(p.consume(s(0), idle: 10))
        XCTAssertNil(p.consume(s(58), idle: 10))
        XCTAssertEqual(p.consume(s(60), idle: 10), deck)
    }

    func testWaitsForAPauseInTheHands() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertNil(p.consume(s(70), idle: 0.5))
        XCTAssertNil(p.consume(s(72), idle: 2.9))
        XCTAssertEqual(p.consume(s(74), idle: 3), deck)
    }

    func testNeverDuringASlideShowThenRightAfterIt() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertNil(p.consume(s(120, presenting: true), idle: 10))
        XCTAssertEqual(p.consume(s(122), idle: 10), deck)
    }

    func testADeckWithNoFileIsNeverSaved() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0, path: "Presentation1"), idle: 10)
        XCTAssertNil(p.consume(s(120, path: "Presentation1"), idle: 10))
        _ = p.consume(s(122, path: nil), idle: 10)
        XCTAssertNil(p.consume(s(240, path: nil), idle: 10))
    }

    func testSavingByHandRestartsTheClock() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        _ = p.consume(s(50, saved: true), idle: 10)
        XCTAssertNil(p.consume(s(52), idle: 10))
        XCTAssertNil(p.consume(s(100), idle: 10))
        XCTAssertEqual(p.consume(s(112), idle: 10), deck)
    }

    func testSwitchingDeckRestartsTheClock() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertNil(p.consume(s(70, path: "/d/b.pptx"), idle: 10))
        XCTAssertEqual(p.consume(s(130, path: "/d/b.pptx"), idle: 10), "/d/b.pptx")
    }

    func testARefusedSaveIsRetriedAFullMinuteLater() {
        var p = PowerPointAutoSavePolicy()
        _ = p.consume(s(0), idle: 10)
        XCTAssertEqual(p.consume(s(60), idle: 10), deck)
        XCTAssertNil(p.consume(s(62), idle: 10))
        XCTAssertEqual(p.consume(s(120), idle: 10), deck)
    }
}
