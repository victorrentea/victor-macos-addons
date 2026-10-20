import XCTest
@testable import VictorAddons

/// 📈 Traffic — the nettop parsing and the three readouts, on lines captured
/// from this Mac's `nettop -d -x -n -J bytes_in,bytes_out,rtt_avg` (2026-10-20).
final class TrafficPolicyTests: XCTestCase {

    private func rows(_ lines: String...) -> [TrafficPolicy.Row] {
        lines.compactMap(TrafficPolicy.parse(line:))
    }

    func testHeaderIsNotARow() {
        XCTAssertNil(TrafficPolicy.parse(line: ",bytes_in,bytes_out,rtt_avg,"))
    }

    func testProcessLineKeepsNameAndPid() {
        XCTAssertEqual(TrafficPolicy.parse(line: "Google Chrome H.45972,8242,10,,"),
                       .init(process: "Google Chrome H", pid: 45972, remote: nil, isTCP: false,
                             bytesIn: 8242, bytesOut: 10, rttMs: nil))
    }

    func testConnectionLineReadsRemoteAndRtt() {
        let row = TrafficPolicy.parse(line: "tcp4 10.131.243.195:61164<->17.57.146.24:5223,0,0,318.72 ms,")
        XCTAssertEqual(row?.remote, "17.57.146.24")
        XCTAssertEqual(row?.isTCP, true)
        XCTAssertEqual(row?.rttMs ?? 0, 318.72, accuracy: 0.001)
    }

    /// nettop cuts the column to its width: `1247.78 m`, `16787.62`.
    func testTruncatedRttStillReadsAsMilliseconds() {
        XCTAssertEqual(TrafficPolicy.parse(line: "tcp4 a:1<->54.163.234.77:443,0,0,1247.78 m,")?.rttMs ?? 0, 1247.78, accuracy: 0.001)
        XCTAssertEqual(TrafficPolicy.parse(line: "tcp4 a:1<->35.171.134.122:443,0,0,16787.62,")?.rttMs ?? 0, 16787.62, accuracy: 0.001)
        XCTAssertNil(TrafficPolicy.parse(line: "tcp4 a:1<->3.211.217.42:443,0,64,0.00 ms,")?.rttMs)
    }

    func testIPv6PortFollowsADot() {
        XCTAssertEqual(TrafficPolicy.host(of: "2a00:1450:400d:80e::200e.443"), "2a00:1450:400d:80e::200e")
        XCTAssertEqual(TrafficPolicy.host(of: "17.57.146.24:5223"), "17.57.146.24")
    }

    func testPrivatePeersAreNotInternetLatency() {
        for host in ["10.131.242.139", "192.168.1.5", "172.20.0.3", "127.0.0.1", "169.254.1.1", "100.101.0.2", "fe80::1", "::1", "*"] {
            XCTAssertFalse(TrafficPolicy.isPublic(host), host)
        }
        XCTAssertTrue(TrafficPolicy.isPublic("160.79.104.10"))
        XCTAssertTrue(TrafficPolicy.isPublic("2a00:1450::1"))
    }

    /// Connections that moved bytes this second win over idle ones, whose RTT is
    /// whatever it was when they last spoke; the LAN tablet is ignored.
    func testLatencyIsMedianOfActivePublicConnections() {
        let l = TrafficPolicy.latency(of: rows(
            "tcp4 a:1<->160.79.104.10:443,500,20,120.00 ms,",
            "tcp4 a:2<->172.64.155.209:443,90,0,180.00 ms,",
            "tcp4 a:3<->108.138.51.81:443,10,10,150.00 ms,",
            "tcp4 a:4<->35.171.134.122:443,0,0,16787.62,",
            "tcp4 a:7000<->10.131.242.139:60950,999,999,2764.88 m,"
        ))
        XCTAssertEqual(l?.ms, 150)
        XCTAssertEqual(l?.connections, 3)
    }

    func testIdleConnectionsStillGiveALatency() {
        let l = TrafficPolicy.latency(of: rows(
            "tcp4 a:1<->160.79.104.10:443,0,0,100.00 ms,",
            "tcp4 a:2<->172.64.155.209:443,0,0,200.00 ms,"
        ))
        XCTAssertEqual(l?.ms, 150)
    }

    func testNoConnectionNoLatency() {
        XCTAssertNil(TrafficPolicy.latency(of: rows("udp4 *:5353<->*:*,4823,320,,")))
    }

    /// Two Chrome helpers fold into one Chrome; silent processes are not listed.
    func testTopAppsFoldHelpersAndRankByTotal() {
        let top = TrafficPolicy.topApps(of: rows(
            "Google Chrome H.1,1000,100,,",
            "Google Chrome H.2,3000,0,,",
            "mDNSResponder.220,2000,0,,",
            "adb.1914,500,500,,",
            "Slack.9,10,0,,",
            "launchd.1,0,0,,"
        )) { $0.process!.hasPrefix("Google Chrome") ? "Google Chrome" : $0.process! }
        XCTAssertEqual(top.map(\.name), ["Google Chrome", "mDNSResponder", "adb"])
        XCTAssertEqual(top.first, .init(name: "Google Chrome", bytesIn: 4000, bytesOut: 100))
    }

    func testAppNameIsTheOutermostBundle() {
        XCTAssertEqual(TrafficPolicy.appName(executablePath:
            "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            "Google Chrome")
        XCTAssertNil(TrafficPolicy.appName(executablePath: "/usr/sbin/mDNSResponder"))
    }

    func testRateUnits() {
        XCTAssertEqual(TrafficPolicy.rate(512), "512 B/s")
        XCTAssertEqual(TrafficPolicy.rate(140_400), "140 KB/s")
        XCTAssertEqual(TrafficPolicy.rate(2_345_000), "2.3 MB/s")
    }

    func testCounterWrapAt4GB() {
        XCTAssertEqual(TrafficPolicy.delta(100, UInt32.max - 99), 200)
    }
}
