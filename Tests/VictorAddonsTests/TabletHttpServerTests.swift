import XCTest
@testable import VictorAddons

final class TabletHttpServerTests: XCTestCase {
    func testParsePathExtractsPathFromHttpRequestLine() {
        let request = "GET /test/transcription/start HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertEqual(TabletHttpServer.parsePath(request), "/test/transcription/start")
    }

    func testRouteMapsTranscriptionControlEndpoints() {
        // Transcription runs automatically on AC; the only headless hook left is
        // a force-(re)start for E2E checks. Stop/toggle/exit-window were removed.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcription/start"), .testTranscriptionStart)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcription/stop"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/transcription/toggle"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/state"), .testState)
    }

    func testRouteMapsBreakSummaryTestHook() {
        // Fires the ☕️ break-summary delta run now, bypassing the >= 5 min +
        // cooldown gates (same Terminal flow a real break triggers).
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/break-summary"), .testBreakSummary)
    }

    func testRouteMapsBellTestHook() {
        // /test/bell with no query → a nil name (AppDelegate substitutes a sample);
        // ?name=… carries the caller through so the card can preview a real name.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/bell"), .testBell(nil))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/bell?name=Ana%20Pop"), .testBell("Ana Pop"))
    }

    func testRouteUnknownForUnsupportedPath() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/unknown"), .unknown)
    }

    func testVideoRoutesStayLocalDespiteTheSoundInTheirPath() {
        // The 🎵 soundtrack-only hooks live under /video/sound/… and /test/video/…;
        // the proxy's "/sound/" prefix is a LEADING match precisely so these are
        // not mistaken for soundboard traffic and shipped off to 55124.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/videos"), .videos)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/video/sound/stop"), .videoSoundStop)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/video/sound/intro"), .videoSoundPlay("intro", nil))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/video/stop"), .videoStop)
    }
}
