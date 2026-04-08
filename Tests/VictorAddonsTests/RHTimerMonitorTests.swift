import XCTest
@testable import VictorAddons

final class RHTimerMonitorTests: XCTestCase {

    func testNoCallbackIfNeverVisible() {
        var fired = false
        let monitor = RHTimerMonitor(windowChecker: { false })
        monitor.onBreakEnded = { fired = true }
        monitor.checkOnce()
        monitor.checkOnce()
        XCTAssertFalse(fired)
    }

    func testNoCallbackIfAlwaysVisible() {
        var fired = false
        let monitor = RHTimerMonitor(windowChecker: { true })
        monitor.onBreakEnded = { fired = true }
        monitor.checkOnce()
        monitor.checkOnce()
        XCTAssertFalse(fired)
    }

    func testCallbackFiredOnVisibleToHiddenTransition() {
        var callCount = 0
        var isVisible = true
        let monitor = RHTimerMonitor(windowChecker: { isVisible })
        monitor.onBreakEnded = { callCount += 1 }

        monitor.checkOnce()   // visible — no callback
        isVisible = false
        monitor.checkOnce()   // hidden after visible — fires callback
        XCTAssertEqual(callCount, 1)
    }

    func testCallbackFiredOnlyOnce() {
        var callCount = 0
        var isVisible = true
        let monitor = RHTimerMonitor(windowChecker: { isVisible })
        monitor.onBreakEnded = { callCount += 1 }

        monitor.checkOnce()   // visible
        isVisible = false
        monitor.checkOnce()   // fires
        monitor.checkOnce()   // still hidden — no repeat
        XCTAssertEqual(callCount, 1)
    }

    func testCallbackFiredAgainAfterReappearance() {
        var callCount = 0
        var isVisible = false
        let monitor = RHTimerMonitor(windowChecker: { isVisible })
        monitor.onBreakEnded = { callCount += 1 }

        isVisible = true
        monitor.checkOnce()   // visible
        isVisible = false
        monitor.checkOnce()   // fires (1)
        isVisible = true
        monitor.checkOnce()   // visible again
        isVisible = false
        monitor.checkOnce()   // fires (2)
        XCTAssertEqual(callCount, 2)
    }
}
