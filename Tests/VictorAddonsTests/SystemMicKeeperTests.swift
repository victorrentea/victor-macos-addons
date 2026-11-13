import XCTest
@testable import VictorAddons

/// `SystemMicKeeper.target` — which input the system default is kept on (2026-11-13).
final class SystemMicKeeperTests: XCTestCase {

    private let desk = ["MacBook Pro Microphone", "Elgato Wave XLR", "Wireless Mic Rx", "From Walkie", "ZoomAudioDevice"]

    func testAutomaticIsTheFirstRungPresent() {
        XCTAssertEqual(SystemMicKeeper.target(choice: "auto", inputs: desk), "Elgato Wave XLR")
        XCTAssertEqual(SystemMicKeeper.target(choice: "auto", inputs: ["MacBook Pro Microphone", "Wireless Mic Rx"]), "Wireless Mic Rx")
        XCTAssertEqual(SystemMicKeeper.target(choice: "auto", inputs: ["From Walkie", "MacBook Pro Microphone"]), "MacBook Pro Microphone")
    }

    func testThePickWinsWhenPluggedInAndFallsBackWhenNot() {
        XCTAssertEqual(SystemMicKeeper.target(choice: "rx", inputs: desk), "Wireless Mic Rx")
        XCTAssertEqual(SystemMicKeeper.target(choice: "rx", inputs: ["MacBook Pro Microphone", "Elgato Wave XLR"]), "Elgato Wave XLR")
    }

    func testNothingOfTheRosterMeansHandsOff() {
        XCTAssertNil(SystemMicKeeper.target(choice: "auto", inputs: ["From Walkie", "ZoomAudioDevice", "Microsoft Teams Audio"]))
    }

    func testABannedHeadsetIsNeverTheTarget() {
        XCTAssertNil(SystemMicKeeper.target(choice: "auto", inputs: ["WH-1000XM3"]))
        XCTAssertEqual(SystemMicKeeper.target(choice: "auto", inputs: ["WH-1000XM3", "MacBook Pro Microphone"]), "MacBook Pro Microphone")
    }

    func testTheHoldFileIsHonouredForTenMinutes() throws {
        try FileManager.default.createDirectory(at: MicPreference.folder, withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: SystemMicKeeper.holdFile.path)
        let before = (try? FileManager.default.attributesOfItem(atPath: SystemMicKeeper.holdFile.path))?[.modificationDate] as? Date
        defer {
            if existed, let before { try? FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: SystemMicKeeper.holdFile.path) }
            else { try? FileManager.default.removeItem(at: SystemMicKeeper.holdFile) }
        }
        FileManager.default.createFile(atPath: SystemMicKeeper.holdFile.path, contents: nil)
        let touched = Date()
        try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: SystemMicKeeper.holdFile.path)
        XCTAssertTrue(SystemMicKeeper.held(now: touched.addingTimeInterval(599)))
        XCTAssertFalse(SystemMicKeeper.held(now: touched.addingTimeInterval(601)))
    }
}
