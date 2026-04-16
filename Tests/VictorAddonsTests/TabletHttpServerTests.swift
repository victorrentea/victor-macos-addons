import XCTest
@testable import VictorAddons

final class TabletHttpServerTests: XCTestCase {
    func testParsePathExtractsPathFromHttpRequestLine() {
        let request = "GET /test/transcription/toggle HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertEqual(TabletHttpServer.parsePath(request), "/test/transcription/toggle")
    }

    func testRouteMapsTranscriptionControlEndpoints() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcription/start"), .testTranscriptionStart)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcription/stop"), .testTranscriptionStop)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcription/toggle"), .testTranscriptionToggle)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/state"), .testState)
    }

    func testRouteMapsEffectEndpointWithNestedName() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/pulse/stop"), .effect("pulse/stop"))
    }

    func testRouteUnknownForUnsupportedPath() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/unknown"), .unknown)
    }
}
