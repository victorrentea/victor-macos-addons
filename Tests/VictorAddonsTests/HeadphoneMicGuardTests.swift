import XCTest
@testable import VictorAddons

final class HeadphoneMicGuardTests: XCTestCase {

    private let inputs = ["WH-1000XM3", "Wireless Mic Rx", "MacBook Pro Microphone", "Iriun Webcam Audio"]

    func testHeadsetIsMovedToTheBestMicOnTheLadder() {
        XCTAssertEqual(HeadphoneMicGuard.replacement(current: "WH-1000XM3", inputs: inputs), "Wireless Mic Rx")
    }

    func testWithoutTheDjiFallsBackToTheBuiltIn() {
        XCTAssertEqual(HeadphoneMicGuard.replacement(current: "WH-1000XM3",
                                                     inputs: ["Iriun Webcam Audio", "WH-1000XM3", "MacBook Pro Microphone"]),
                       "MacBook Pro Microphone")
    }

    func testOffLadderInputIsStillBetterThanTheHeadset() {
        XCTAssertEqual(HeadphoneMicGuard.replacement(current: "WH-1000XM3", inputs: ["WH-1000XM3", "Iriun Webcam Audio"]),
                       "Iriun Webcam Audio")
    }

    func testAnyOtherDefaultIsLeftAlone() {
        XCTAssertNil(HeadphoneMicGuard.replacement(current: "MacBook Pro Microphone", inputs: inputs))
        XCTAssertNil(HeadphoneMicGuard.replacement(current: "Bose QC45", inputs: inputs))
    }

    func testSuccessorsAreBannedToo() {
        XCTAssertTrue(HeadphoneMicGuard.isBanned("WH-1000XM5"))
    }

    func testNoAlternativeMeansNoMove() {
        XCTAssertNil(HeadphoneMicGuard.replacement(current: "WH-1000XM3", inputs: ["WH-1000XM3"]))
    }
}
