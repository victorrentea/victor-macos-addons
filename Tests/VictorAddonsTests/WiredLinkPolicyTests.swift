import XCTest
@testable import VictorAddons

/// 🔌 Wired status row — the decision, without a cable.
final class WiredLinkPolicyTests: XCTestCase {

    private func port(_ name: String, active: Bool, _ ips: String...) -> WiredLinkPolicy.Port {
        .init(displayName: name, linkActive: active, ipv4: ips)
    }

    func testDongleWithAddressIsConnected() {
        XCTAssertEqual(WiredLinkPolicy.state(of: [port("USB 10/100/1000 LAN", active: true, "192.168.1.23")]),
                       .connected(ip: "192.168.1.23"))
    }

    func testLinkWithoutAddressIsCableInNoIP() {
        XCTAssertEqual(WiredLinkPolicy.state(of: [port("AX88179A", active: true)]), .noAddress)
    }

    /// A self-assigned address means DHCP never answered — no network behind
    /// the cable, which is exactly what the row is there to say.
    func testSelfAssignedAddressIsNotConnected() {
        XCTAssertEqual(WiredLinkPolicy.state(of: [port("Ethernet", active: true, "169.254.10.4")]), .noAddress)
    }

    func testCableOutIsDisconnected() {
        XCTAssertEqual(WiredLinkPolicy.state(of: [port("USB 10/100/1000 LAN", active: false)]), .disconnected)
        XCTAssertEqual(WiredLinkPolicy.state(of: []), .disconnected)
    }

    /// What this Mac reports with nothing plugged: the bridge's member ports
    /// and the anpi placeholders. A Mac-to-Mac Thunderbolt cable brings those
    /// up — that is not wired internet.
    func testThunderboltBridgePortsAndPlaceholdersAreNotCables() {
        let ports = [
            port("Thunderbolt 1", active: true, "169.254.1.1"),
            port("Ethernet Adapter (en4)", active: true, "10.0.0.2"),
        ]
        XCTAssertEqual(WiredLinkPolicy.state(of: ports), .disconnected)
        XCTAssertTrue(WiredLinkPolicy.isCable(displayName: "Thunderbolt Ethernet Slot 0"))
    }

    func testAnyConnectedPortWinsOverOneStillAsking() {
        let ports = [port("AX88179A", active: true), port("USB 10/100/1000 LAN", active: true, "10.1.2.3")]
        XCTAssertEqual(WiredLinkPolicy.state(of: ports), .connected(ip: "10.1.2.3"))
    }
}
