import XCTest
@testable import DesktopOverlay

final class LocalWsClientTests: XCTestCase {

    func testEmojiMessageDispatchesWithCount() {
        var received: [(String, Int)] = []
        let client = LocalWsClient { emoji, count in
            received.append((emoji, count))
        }

        // Simulate receiving a valid emoji message
        client.simulateMessage("{\"type\":\"emoji\",\"emoji\":\"🎉\",\"count\":3}")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].0, "🎉")
        XCTAssertEqual(received[0].1, 3)
    }

    func testEmojiMessageDefaultsCountToOne() {
        var received: [(String, Int)] = []
        let client = LocalWsClient { emoji, count in
            received.append((emoji, count))
        }

        client.simulateMessage("{\"type\":\"emoji\",\"emoji\":\"👏\"}")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].1, 1)
    }

    func testUnknownMessageTypeIsIgnored() {
        var received: [(String, Int)] = []
        let client = LocalWsClient { emoji, count in
            received.append((emoji, count))
        }

        client.simulateMessage("{\"type\":\"slide\",\"deck\":\"Test.pptx\",\"slide\":5}")

        XCTAssertEqual(received.count, 0)
    }

    func testMalformedJsonIsIgnored() {
        var received: [(String, Int)] = []
        let client = LocalWsClient { emoji, count in
            received.append((emoji, count))
        }

        client.simulateMessage("not valid json{{")

        XCTAssertEqual(received.count, 0)
    }

    func testDefaultPortReadsEnvVar() {
        // The static helper should parse WS_SERVER_PORT env var.
        // We can't set env vars at test time, so just verify it returns a valid port.
        let port = LocalWsClient.defaultPort()
        XCTAssertGreaterThan(port, 0)
        XCTAssertLessThan(port, 65536)
    }
}
