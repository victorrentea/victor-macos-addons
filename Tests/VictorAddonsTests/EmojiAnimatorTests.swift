import XCTest
import ImageIO
@testable import VictorAddons

final class EmojiAnimatorTests: XCTestCase {
    // NOTE: `testMonitorEmojiUsesBreakingGlassSound` and `testHeartEmojiHasNoSoundEffect`
    // were removed — they referenced `EmojiAnimator.soundEffect(for:)`, which no longer
    // exists (the emoji→sound mapping was refactored into the show* effect methods,
    // which now play "90_breaking-glass.mp3" directly). The stale references broke
    // compilation of the whole test target on master.

    func testBreakingGlassResourceIsBundled() {
        let url = Bundle.module.url(forResource: "breaking-glass.mp3", withExtension: nil, subdirectory: "Resources")
        XCTAssertNotNil(url)
    }

    /// The 🔥 Phoenix asset must bundle into the app AND decode as the full
    /// 28-frame transparent animation the effect loops — this calls the exact
    /// `CGImageSource` loader `showPhoenix()` uses, so we catch a missing,
    /// corrupt, or flattened asset headlessly (no on-screen firing).
    func testPhoenixAssetBundlesAsTransparentMultiFrame() {
        let frames = EmojiAnimator.loadPhoenixFrames()
        XCTAssertEqual(frames.count, 28, "phoenix.png should decode to 28 frames")
        let first = frames.first
        XCTAssertEqual(first?.width, 506)
        XCTAssertEqual(first?.height, 506)
        // Transparent (luminance-keyed) frames carry an alpha channel — not opaque.
        XCTAssertNotEqual(first?.alphaInfo, CGImageAlphaInfo.none)
    }
}
