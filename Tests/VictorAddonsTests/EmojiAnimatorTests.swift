import XCTest
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
}
