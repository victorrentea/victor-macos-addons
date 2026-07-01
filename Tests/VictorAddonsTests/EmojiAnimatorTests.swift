import XCTest
import ImageIO
import QuartzCore
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

    func testNukeLockedReticleGrowsAndRotatesSlowlyUntilStrike() {
        let animations = EmojiAnimator.makeBombReticleLockAnimations(remaining: 0.75)

        let grow = animations.grow
        XCTAssertEqual(grow.keyPath, "transform.scale")
        XCTAssertEqual(grow.fromValue as? Double, 1.0)
        XCTAssertEqual(grow.toValue as? Double, 2.2)
        XCTAssertEqual(grow.duration, 0.75, accuracy: 0.001)

        let rotate = animations.rotate
        XCTAssertEqual(rotate.keyPath, "transform.rotation.z")
        XCTAssertEqual(rotate.fromValue as? Double, 0.0)
        XCTAssertEqual(rotate.toValue as? Double ?? 0, -Double.pi / 8, accuracy: 0.001)
        XCTAssertEqual(rotate.duration, grow.duration, accuracy: 0.001)
        XCTAssertEqual(rotate.fillMode, CAMediaTimingFillMode.forwards)
        XCTAssertFalse(rotate.isRemovedOnCompletion)
    }

    func testBombReticleUsesThreeFilledTrianglesOnCircle() {
        let layer = EmojiAnimator.makeBombReticleLayer()
        let shapes = layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        let stroked = shapes.filter { $0.strokeColor != nil }
        let filled = shapes.filter { ($0.fillColor?.alpha ?? 0) > 0 }

        XCTAssertEqual(layer.bounds.width, 180, accuracy: 0.001)
        XCTAssertEqual(layer.bounds.height, 180, accuracy: 0.001)
        XCTAssertEqual(stroked.count, 1)
        XCTAssertEqual(filled.count, 3)
    }

    func testBombReticleIsGrayWhenAimingAndRedWhenLocked() {
        let aiming = EmojiAnimator.makeBombReticleLayer()
        let locked = EmojiAnimator.makeBombReticleLayer(armed: true)
        let aimingRing = aiming.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.strokeColor != nil }
        let lockedRing = locked.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.strokeColor != nil }

        XCTAssertEqual(aimingRing?.strokeColor, NSColor.systemGray.cgColor)
        XCTAssertEqual(lockedRing?.strokeColor, NSColor.systemRed.cgColor)
    }

    func testBombStrikeContinuesRotationFromCurrentAngleDuringFade() {
        let rotate = EmojiAnimator.makeBombReticleStrikeRotateAnimation(from: -0.2, duration: 0.45)

        XCTAssertEqual(rotate.keyPath, "transform.rotation.z")
        XCTAssertEqual(rotate.fromValue as? Double ?? 0, -0.2, accuracy: 0.001)
        XCTAssertLessThan(rotate.toValue as? Double ?? 0, -0.2)
        XCTAssertEqual(rotate.duration, 0.45, accuracy: 0.001)
        XCTAssertEqual(rotate.fillMode, CAMediaTimingFillMode.forwards)
        XCTAssertFalse(rotate.isRemovedOnCompletion)
    }

    func testMinigunAllowsHalfSecondAimLeadInAndSmallerBulletHoles() {
        XCTAssertEqual(EmojiAnimator.minigunAimLeadIn, 0.5, accuracy: 0.001)
        XCTAssertEqual(EmojiAnimator.minigunBulletHoleScale, 0.7, accuracy: 0.001)
    }

    /// The 🔥 Phoenix asset must bundle into the app AND decode as the full
    /// 28-frame transparent animation the effect loops — this calls the exact
    /// `CGImageSource` loader `showPhoenix()` uses, so we catch a missing,
    /// corrupt, or flattened asset headlessly (no on-screen firing). The art is
    /// cropped tight to the flame's changing-pixel bounding box (226×350).
    func testPhoenixAssetBundlesAsTransparentMultiFrame() {
        let frames = EmojiAnimator.loadPhoenixFrames()
        XCTAssertEqual(frames.count, 28, "phoenix.png should decode to 28 frames")
        let first = frames.first
        XCTAssertEqual(first?.width, 226)
        XCTAssertEqual(first?.height, 340)
        // Transparent (luminance-keyed) frames carry an alpha channel — not opaque.
        XCTAssertNotEqual(first?.alphaInfo, CGImageAlphaInfo.none)
    }

    /// Regression guard for the lingering-white-background bug: a previous APNG
    /// build left frames 1…27 with an *opaque white* sub-rectangle (only frame 0
    /// was transparent), so the rising flame dragged a white box behind it. Every
    /// frame's four corners must now be fully transparent.
    func testPhoenixEveryFrameHasTransparentCorners() {
        let frames = EmojiAnimator.loadPhoenixFrames()
        XCTAssertEqual(frames.count, 28)
        for (i, cg) in frames.enumerated() {
            let w = cg.width, h = cg.height
            // Buffer starts fully transparent (0); drawing source-over keeps the
            // source's own alpha — so a transparent background reads back as 0.
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: &px, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                XCTFail("ctx for frame \(i)"); return
            }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
            for (x, y) in corners {
                let a = px[(y * w + x) * 4 + 3]   // alpha byte (premultipliedLast)
                XCTAssertEqual(a, 0, "frame \(i) corner (\(x),\(y)) not transparent (alpha=\(a))")
            }
            // Sanity: the flame itself IS present/opaque somewhere — guards the
            // corner check from passing vacuously (e.g. if the draw drew nothing).
            let maxAlpha = stride(from: 3, to: px.count, by: 4).map { px[$0] }.max() ?? 0
            XCTAssertGreaterThan(maxAlpha, 200, "frame \(i) has no opaque flame pixels")
        }
    }
}
