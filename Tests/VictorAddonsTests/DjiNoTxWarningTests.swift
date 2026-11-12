import AppKit
import XCTest
@testable import VictorAddons

final class DjiNoTxWarningTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func warning() -> DjiNoTxWarning { DjiNoTxWarning(screensProvider: { [] }, sound: {}) }

    func testReceiverPluggedInWithNoTxWarns() {
        let w = warning()
        w.gateChanged(.absent)
        w.gateChanged(.noTx)
        XCTAssertTrue(w.isShown)
    }

    func testAppStartingWithNoTxWarns() {
        let w = warning()
        w.gateChanged(.noTx)
        XCTAssertTrue(w.isShown)
    }

    func testATxThatDiesIsTheRedAlarmsJobNotThisOne() {
        let w = warning()
        w.gateChanged(.absent)
        w.gateChanged(.linked)
        w.gateChanged(.noTx)
        XCTAssertFalse(w.isShown)
    }

    func testTxComingOnOrReceiverUnpluggedTakesItDown() {
        for next in [DjiSourceGate.State.linked, .absent] {
            let w = warning()
            w.gateChanged(.noTx)
            w.gateChanged(next)
            XCTAssertFalse(w.isShown, "\(next)")
        }
    }

    func testDismissedByClickStaysDownUntilTheNextPlugIn() {
        let w = warning()
        w.gateChanged(.noTx)
        w.hide(by: "click")
        w.gateChanged(.noTx)   // a repeated word, not a new plug-in
        XCTAssertFalse(w.isShown)
        w.gateChanged(.absent)
        w.gateChanged(.noTx)
        XCTAssertTrue(w.isShown)
    }
}
