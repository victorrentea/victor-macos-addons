import XCTest
@testable import VictorAddons

/// The seam between this app and Victor Effects: which paths on 55123 are
/// answered here, which are forwarded verbatim to 55124, and how the two halves
/// of `/ping` are spliced back into the one object the tablet parses.
///
/// All of it is pure — `route(forPath:)` and `mergedPing` take strings and
/// return values — so the table can be exercised without either app running.
/// The end-to-end checks (a real snow, a real gong) are the deploy agent's.
final class EffectsProxyRoutingTests: XCTestCase {

    // MARK: - The three effects addons kept

    func testTrainingEndStaysLocal() {
        // 🏁 needs whisper's VICTOR_VOICE pulse to know the room went quiet, and
        // that listener never left this process.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/training-end"), .effect("training-end"))
    }

    func testStopAllStaysLocal() {
        // Local AND forwarded: `respond` runs the local half (🎵 soundtrack,
        // disarm 🏁) and then forwards, in that order. The route itself is local.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/stop-all"), .effect("stop-all"))
    }

    func testFocusPlaylistStaysLocalOnBothSpellings() {
        // 🎧 ⌘⌃F opens a Chrome tab. Nothing is drawn, so nothing moved — and
        // its historic /test/ alias has to stay local with it.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/focus-playlist"), .effect("focus-playlist"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/focus-playlist"), .effect("focus-playlist"))
    }

    func testLocalEffectNamesAreExactlyThoseThree() {
        XCTAssertEqual(TabletHttpServer.localEffectNames,
                       ["training-end", "stop-all", "focus-playlist"])
    }

    // MARK: - Everything else under /effect/ is forwarded

    func testEffectsAreProxiedVerbatimIncludingNestedNamesAndQuery() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/snow"), .proxied("/effect/snow"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/pulse/stop"), .proxied("/effect/pulse/stop"))
        // The query rides along untouched: the flag on the 🏁 progress bar and
        // the emoji burst both carry percent-encoded values that must not be
        // re-encoded on the way through.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/progress-bar/10?rider=%F0%9F%8F%81"),
                       .proxied("/effect/progress-bar/10?rider=%F0%9F%8F%81"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/emoji?e=%E2%98%95&count=3"),
                       .proxied("/effect/emoji?e=%E2%98%95&count=3"))
    }

    func testTrainingEndPrefixIsNotACarveOutForItsChildren() {
        // Only the exact name is local. A hypothetical `/effect/training-end/x`
        // is not one of ours and must not be swallowed by the exception.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effect/training-end/stop"),
                       .proxied("/effect/training-end/stop"))
    }

    // MARK: - The soundboard

    func testSoundRoutesAreProxied() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/play/50_gong.mp3?vol=60"),
                       .proxied("/sound/play/50_gong.mp3?vol=60"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/pressed/40_joker.mp3"),
                       .proxied("/sound/pressed/40_joker.mp3"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/stopped/37_rainbow.mp3"),
                       .proxied("/sound/stopped/37_rainbow.mp3"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/volume/70"), .proxied("/sound/volume/70"))
        // "/sound/stop" preempts playback and is NOT a "/sound/stopped/<file>"
        // report — but both go the same way now, so the distinction is the
        // effects app's to make.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sound/stop"), .proxied("/sound/stop"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/sounds/manifest"), .proxied("/sounds/manifest"))
    }

    func testAlarmAndBtCompensationAreProxied() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/alarm/start"), .proxied("/alarm/start"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/alarm/stop"), .proxied("/alarm/stop"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/bt-compensation"), .proxied("/bt-compensation"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/bt-compensation/800"), .proxied("/bt-compensation/800"))
    }

    func testTilesAndStateAreProxied() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/tiles"), .proxied("/tiles"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/tiles/tiles/sfx_01_baby.jpg"),
                       .proxied("/tiles/tiles/sfx_01_baby.jpg"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/state"), .proxied("/state"))
    }

    // MARK: - The historic /test/<effect> aliases

    func testEffectTestAliasesKeepAnsweringOn55123ByBeingProxied() {
        // Every script, doc and muscle memory points at these on 55123. They are
        // forwarded under the SAME spelling, which is why the effects app serves
        // them too instead of a renamed set.
        for path in ["/test/sonar", "/test/beethoven", "/test/phoenix", "/test/money",
                     "/test/coffee", "/test/coffee/pop", "/test/iris",
                     "/test/snow", "/test/snow/stop",
                     "/test/elephant", "/test/elephant/stop",
                     "/test/claude-peek", "/test/claude-peek/stop",
                     "/test/minion", "/test/counter-strike",
                     "/test/chainsaw", "/test/chainsaw/stop",
                     "/test/fire", "/test/fire/stop", "/test/microwave"] {
            XCTAssertEqual(TabletHttpServer.route(forPath: path), .proxied(path), path)
        }
    }

    func testTheAgentOverlayTestHooksAreProxiedToo() {
        // Their overlay left with the animator; the two hooks did not change
        // name, so they simply became forwarded paths.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/whip"), .proxied("/test/whip"))
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/whip/crack"), .proxied("/test/whip/crack"))
    }

    func testAddonsOwnTestHooksAreNotProxied() {
        // The alias list is exact, not a `/test/` sweep: everything else under
        // /test/ is still answered here.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/state"), .testState)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/break/close"), .testBreakClose)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/tile"), .testTile)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/test/unknown"), .unknown)
    }

    func testAddonsOwnedRoutesStayLocal() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/videos"), .videos)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/hands-off/state"), .handsOffState)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/session/name"), .sessionName)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/link/hide"), .linkHide)
    }

    // MARK: - The webhook back from the effects app

    func testCoffeePoppedWebhookCarriesItsGlobalPoint() {
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effects/event?type=coffee-popped&x=1440.5&y=300"),
                       .effectsEvent(type: "coffee-popped", params: ["x": "1440.5", "y": "300"]))
    }

    func testEffectsEventWithoutATypeIsNotARoute() {
        // No type = nothing to dispatch. A 404 is a clearer answer than a
        // silently ignored 200.
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effects/event"), .unknown)
        XCTAssertEqual(TabletHttpServer.route(forPath: "/effects/event?type="), .unknown)
    }

    func testEffectsEventIsNotSwallowedByTheEffectPrefix() {
        // "/effects/event" vs "/effect/…" differ by one letter; the webhook must
        // not end up forwarded back to the app that sent it.
        if case .proxied = TabletHttpServer.route(forPath: "/effects/event?type=coffee-popped") {
            XCTFail("the webhook must be handled locally, not proxied")
        }
    }

    // MARK: - The /ping merge

    /// What the addons half contributes: a fragment, leading comma, no braces.
    private let extras = ",\"macTimeMs\":1757000000000,\"macTz\":\"Europe/Bucharest\","
        + "\"macLanIps\":[\"192.168.1.7\"],\"macScreenLocked\":false,\"trainingEndArmed\":true"

    func testPingMergeKeepsBothHalvesWhenEffectsIsUp() {
        let effects = "{\"ok\":true,\"app\":\"victor-effects\",\"soundsHash\":\"abc123\","
            + "\"tilesHash\":\"def456\",\"tabletVolume\":70}"
        let merged = EffectsProxy.mergedPing(effectsJSON: effects, extras: extras)

        let obj = json(merged)
        XCTAssertEqual(obj["soundsHash"] as? String, "abc123")
        XCTAssertEqual(obj["tilesHash"] as? String, "def456")
        XCTAssertEqual(obj["tabletVolume"] as? Int, 70)
        XCTAssertEqual(obj["macTz"] as? String, "Europe/Bucharest")
        XCTAssertEqual(obj["macLanIps"] as? [String], ["192.168.1.7"])
        XCTAssertEqual(obj["trainingEndArmed"] as? Bool, true)
        XCTAssertEqual(obj["effectsUp"] as? Bool, true)
        XCTAssertEqual(obj["ok"] as? Bool, true)
    }

    func testPingMergeReportsEffectsDownWithAnEmptyHash() {
        // The empty hash is load-bearing: `MacLink.refreshSyncState` returns
        // early on it, so the tablet does NOT light its amber "the Mac's sounds
        // are stale" dot just because the effects app is stopped.
        let merged = EffectsProxy.mergedPing(effectsJSON: nil, extras: extras)

        let obj = json(merged)
        XCTAssertEqual(obj["ok"] as? Bool, true)
        XCTAssertEqual(obj["effectsUp"] as? Bool, false)
        XCTAssertEqual(obj["soundsHash"] as? String, "")
        // The addons half still answers in full — the clock, the LAN addresses
        // and the 🏁 chip keep working with the effects app stopped.
        XCTAssertEqual(obj["macTz"] as? String, "Europe/Bucharest")
        XCTAssertEqual(obj["trainingEndArmed"] as? Bool, true)
    }

    func testPingMergeTreatsGarbageFromTheEffectsAppAsDown() {
        // A half-written body, an HTML error page, an empty object: anything we
        // cannot splice is reported as down rather than pasted into the answer,
        // where it would break the tablet's parser instead of one field.
        for bad in ["", "not json", "{", "{\"ok\":true", "{}", "   "] {
            let obj = json(EffectsProxy.mergedPing(effectsJSON: bad, extras: extras))
            XCTAssertEqual(obj["effectsUp"] as? Bool, false, "for body <\(bad)>")
            XCTAssertEqual(obj["macTz"] as? String, "Europe/Bucharest", "for body <\(bad)>")
        }
    }

    func testPingMergeSurvivesAnEmptyAddonsFragment() {
        // Before the delegate wires `onPingExtras` there is nothing to splice —
        // the answer must still be valid JSON, not `{…,}`.
        let obj = json(EffectsProxy.mergedPing(effectsJSON: "{\"soundsHash\":\"abc\"}", extras: ""))
        XCTAssertEqual(obj["soundsHash"] as? String, "abc")
        XCTAssertEqual(obj["effectsUp"] as? Bool, true)
    }

    private func json(_ s: String) -> [String: Any] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("not parseable as JSON: \(s)")
            return [:]
        }
        return obj
    }
}
