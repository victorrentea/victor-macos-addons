import XCTest
@testable import VictorAddons

/// 🖥️ The tart VM indicator — which processes count as a running VM, without a VM.
final class TartVMIndicatorTests: XCTestCase {

    /// The exact argv of the wt-lab VM that ran unnoticed for 13½ h on 2026-10-05.
    func testWalkieLabCommandLineIsWtLab() {
        let argv = ["tart", "run", "wt-lab", "--no-graphics", "--no-audio", "--no-clipboard",
                    "--dir", "corpus:/Users/victorrentea/.walkie-talkie/voice-corpus:ro",
                    "--dir", "out:/Users/victorrentea/tart/wt-wispr-out"]
        XCTAssertEqual(TartVMPolicy.vmName(argv: argv), "wt-lab")
    }

    func testFlagValuesBeforeTheNameAreSkipped() {
        XCTAssertEqual(TartVMPolicy.vmName(argv: ["/opt/homebrew/bin/tart", "run", "--dir", "a:/x", "--no-graphics", "lab"]), "lab")
        XCTAssertEqual(TartVMPolicy.vmName(argv: ["tart", "run", "--dir=a:/x", "lab"]), "lab")
    }

    func testOtherTartCommandsAreNotAVM() {
        XCTAssertNil(TartVMPolicy.vmName(argv: ["tart", "list"]))
        XCTAssertNil(TartVMPolicy.vmName(argv: ["tart", "stop", "wt-lab"]))
        XCTAssertNil(TartVMPolicy.vmName(argv: ["start", "run", "wt-lab"]))
    }

    func testUptimeLabels() {
        XCTAssertEqual(TartVMPolicy.uptime(42 * 60), "42m")
        XCTAssertEqual(TartVMPolicy.uptime(13 * 3600 + 36 * 60), "13h 36m")
        XCTAssertEqual(TartVMPolicy.uptime(53 * 3600), "2d 5h")
    }

    /// argc, executable, padding, argv, environment — the KERN_PROCARGS2 layout.
    func testProcArgs2ParsesArgvAndTartHome() {
        var bytes: [UInt8] = []
        var argc = Int32(3)
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        for s in ["/opt/homebrew/bin/tart"] { bytes += Array(s.utf8) + [0] }
        bytes += [0, 0, 0]
        for s in ["tart", "run", "wt-lab", "HOME=/Users/v", "TART_HOME=/Users/v/tart", ""] { bytes += Array(s.utf8) + [0] }

        let parsed = TartVMIndicator.parseProcArgs2(bytes)
        XCTAssertEqual(parsed?.executable, "/opt/homebrew/bin/tart")
        XCTAssertEqual(parsed?.argv, ["tart", "run", "wt-lab"])
        XCTAssertEqual(parsed?.env["TART_HOME"], "/Users/v/tart")
    }
}
