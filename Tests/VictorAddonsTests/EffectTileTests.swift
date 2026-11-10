import XCTest
@testable import VictorAddons

/// 🥁 The break gong is played as the effects app's tile #50 — the same routes a press uses.
final class EffectTileTests: XCTestCase {
    func testTheGongIsTheTilesOwnPlayAndStop() {
        XCTAssertEqual(EffectTile.playPath("50_gong.mp3"), "/sound/play/50_gong.mp3")
        XCTAssertEqual(EffectTile.stopPath("50_gong.mp3"), "/sound/stop/50_gong.mp3")
    }

    func testTheEffectsAppRoutesThemToTheTile() {
        XCTAssertEqual(TabletHttpServer.route(forPath: EffectTile.playPath("50_gong.mp3")),
                       .proxied("/sound/play/50_gong.mp3"))
    }
}
