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

    func testRouteMapsEffectEndpointWithNestedName() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/pulse/stop"), .effect("pulse/stop"))
    }

    func testRoutePhoenixTestAndEffectEndpoints() {
        // Both the headless test hook and the generic /effect/ path dispatch the
        // phoenix overlay through onEffect("phoenix").
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/phoenix"), .effect("phoenix"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/phoenix"), .effect("phoenix"))
    }

    func testRouteIrisTestAndEffectEndpoints() {
        // The 🕳️ iris-close blackout: both the headless test hook and the generic
        // /effect/ path dispatch through onEffect("iris"). The tablet itself
        // drives it via /sound/pressed/31_tarzan.mp3 (mapped to "iris" in
        // SoundEffectMap).
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/iris"), .effect("iris"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/iris"), .effect("iris"))
    }

    func testRouteUnknownForUnsupportedPath() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/unknown"), .unknown)
    }

    func testRouteMapsSoundPressedAndStopped() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/pressed/40_joker.mp3"), .soundPressed("40_joker.mp3"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/stopped/37_rainbow.mp3"), .soundStopped("37_rainbow.mp3"))
    }

    func testSoundStopExactStillDistinctFromStopped() {
        // "/sound/stop" preempts tablet-routed playback; it must NOT be parsed
        // as a "/sound/stopped/<file>" report.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/stop"), .soundStop)
    }

    func testSoundEffectMapDrivesBloodAndKeepsSirenSpecial() {
        XCTAssertEqual(SoundEffectMap.pressEffect(for: "40_joker.mp3"), "blood-drip")
        XCTAssertEqual(SoundEffectMap.pressEffect(for: "03_explosion.mp3"), "explosion")
        XCTAssertEqual(SoundEffectMap.stopEffect(for: "37_rainbow.mp3"), "rainbow/stop")
        // Siren stays special-cased on the tablet (alarm overlay) — not mapped here.
        XCTAssertNil(SoundEffectMap.pressEffect(for: "02_siren.mp3"))
        XCTAssertNil(SoundEffectMap.pressEffect(for: "99_nonexistent.mp3"))
    }
}
