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

    // MARK: - 🐘 Elephant in the room (⌘⌃⇧E)

    func testElephantStandsOnTheBottomEdgeOfTheLeftHalf() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let frame = EmojiAnimator.elephantFrame(in: bounds, aspect: 1082.0 / 881.0)

        // Never crosses the middle: the right half is where the thing being
        // talked about lives.
        XCTAssertLessThanOrEqual(frame.maxX, bounds.midX)
        // Left edge and bottom edge, one margin off each.
        XCTAssertEqual(frame.minX, bounds.width * 0.015, accuracy: 0.01)
        XCTAssertEqual(frame.minY, bounds.width * 0.015, accuracy: 0.01)
        XCTAssertEqual(frame.width / frame.height, 1082.0 / 881.0, accuracy: 0.001)
    }

    func testElephantIsHeightCappedOnAScreenTooShortForHalfItsWidth() {
        // A wide, short screen: half the width would be taller than the screen,
        // and an elephant cropped at the knees is only ever seen on the projector.
        let bounds = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let aspect: CGFloat = 1082.0 / 881.0
        let frame = EmojiAnimator.elephantFrame(in: bounds, aspect: aspect)

        XCTAssertEqual(frame.height, bounds.height * 0.62, accuracy: 0.01)
        XCTAssertEqual(frame.width / frame.height, aspect, accuracy: 0.001)
        XCTAssertLessThan(frame.maxY, bounds.height)
    }

    /// The point of the picture is that it has no background of its own — a
    /// white rectangle on the desktop reads as "an image opened", not as an
    /// elephant standing in the room. Guards a future re-export from losing it.
    func testElephantShipsCutOutWithAnAlphaChannel() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "elephant.png", withExtension: nil, subdirectory: "Resources"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertNotEqual(image.alphaInfo, .none)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipFirst)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipLast)
        // Cropped to the animal itself, so the frame it is placed in is the
        // elephant and not a transparent border around one.
        XCTAssertGreaterThan(image.width, 500)
        XCTAssertGreaterThan(image.height, 500)
    }

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
        XCTAssertEqual(rotate.toValue as? Double ?? 0, EmojiAnimator.bombReticleRotationSpeed * 0.75, accuracy: 0.001)
        XCTAssertEqual(rotate.duration, grow.duration, accuracy: 0.001)
        XCTAssertEqual(rotate.timingFunction, CAMediaTimingFunction(name: .linear))
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
        XCTAssertEqual(stroked.count, 3)
        XCTAssertEqual(filled.count, 3)
    }

    func testBombReticleRingIsThinSegmentedAndTriangleCentersSitOnCirclePointingInward() {
        let layer = EmojiAnimator.makeBombReticleLayer()
        let shapes = layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        let ringSegments = shapes.filter { $0.strokeColor != nil }
        let triangles = shapes.filter { ($0.fillColor?.alpha ?? 0) > 0 }
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)

        XCTAssertEqual(ringSegments.count, 3)
        XCTAssertTrue(ringSegments.allSatisfy { abs($0.lineWidth - 3.85) < 0.001 })
        XCTAssertEqual(triangles.count, 3)
        for triangle in triangles {
            let points = triangle.path?.testPoints() ?? []
            XCTAssertEqual(points.count, 3)
            let centroid = CGPoint(
                x: points.map(\.x).reduce(0, +) / 3,
                y: points.map(\.y).reduce(0, +) / 3
            )
            let distances = points.map { hypot($0.x - center.x, $0.y - center.y) }
            XCTAssertEqual(hypot(centroid.x - center.x, centroid.y - center.y), 54, accuracy: 0.001)
            XCTAssertEqual((distances.max() ?? 0) - (distances.min() ?? 0), 28.834, accuracy: 0.001)
            XCTAssertEqual(distances.min() ?? 0, distances[0], accuracy: 0.001, "the triangle tip should point inward")
        }
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
        XCTAssertEqual(rotate.toValue as? Double ?? 0, -0.2 + EmojiAnimator.bombReticleRotationSpeed * 0.45, accuracy: 0.001)
        XCTAssertEqual(rotate.duration, 0.45, accuracy: 0.001)
        XCTAssertEqual(rotate.timingFunction, CAMediaTimingFunction(name: .linear))
        XCTAssertEqual(rotate.fillMode, CAMediaTimingFillMode.forwards)
        XCTAssertFalse(rotate.isRemovedOnCompletion)
    }

    func testMinigunAllowsHalfSecondAimLeadInAndSmallerBulletHoles() {
        XCTAssertEqual(EmojiAnimator.minigunAimLeadIn, 0.5, accuracy: 0.001)
        XCTAssertEqual(EmojiAnimator.minigunBulletHoleScale, 0.7, accuracy: 0.001)
    }

    /// The gun slides along the bottom edge at HALF the cursor's travel: swing the
    /// crosshair 400px right and the gun follows 200px. Because the mapping is
    /// `mouseX / 2` (not an offset from a rest point), it also keeps the gun in the
    /// west half whatever you aim at — always behind the bullets it fires.
    func testMinigunGunTracksTheMouseAtHalfSpeedAndStaysInTheWestHalf() {
        let width: CGFloat = 1600

        XCTAssertEqual(EmojiAnimator.minigunBodyX(forMouseX: 0), 0, accuracy: 0.001)
        XCTAssertEqual(EmojiAnimator.minigunBodyX(forMouseX: width), width / 2, accuracy: 0.001,
                       "cursor at the east edge must still leave the gun in the west half")

        // Half travel, measured as a ratio between two cursor positions.
        let near = EmojiAnimator.minigunBodyX(forMouseX: 300)
        let far = EmojiAnimator.minigunBodyX(forMouseX: 700)
        XCTAssertEqual(far - near, 200, accuracy: 0.001)

        // The gun is never to the right of the cursor it is shooting at.
        for mouseX in stride(from: CGFloat(0), through: width, by: 50) {
            XCTAssertLessThanOrEqual(EmojiAnimator.minigunBodyX(forMouseX: mouseX), mouseX)
        }

        // Continuity with the placement this replaced: a cursor in the middle of
        // the west half parks the gun on the old fixed W/8.
        XCTAssertEqual(EmojiAnimator.minigunBodyX(forMouseX: width / 4), width * 0.125, accuracy: 0.001)
    }

    /// `position` moves the sprite FRAME, but the gun body sits off-centre in a
    /// frame that is mostly empty sky for the casings — so the layer x has to be
    /// biased by that offset, or the emptiness lands on target and the gun walks
    /// off the west edge.
    func testMinigunLayerXOffsetsForTheGunBodySittingOffCentreInTheFrame() {
        let spriteWidth: CGFloat = 800
        let layerX = EmojiAnimator.minigunLayerX(forBodyX: 200, spriteWidth: spriteWidth)

        // Mirrored sprite: the body's 0.758 reflects to 0.242, i.e. left of centre,
        // so the frame must be pushed RIGHT to bring the body back onto 200.
        XCTAssertGreaterThan(layerX, 200)
        XCTAssertEqual(layerX, 200 + (0.5 - 0.242) * spriteWidth, accuracy: 0.5)

        // And the mapping is a pure translation: same shift at any target x.
        let shiftA = EmojiAnimator.minigunLayerX(forBodyX: 0, spriteWidth: spriteWidth)
        let shiftB = EmojiAnimator.minigunLayerX(forBodyX: 640, spriteWidth: spriteWidth) - 640
        XCTAssertEqual(shiftA, shiftB, accuracy: 0.001)
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

    // MARK: - Per-participant emoji glow

    func testGlowColorParsesHex() {
        let c = EmojiAnimator.nsColor(fromHex: "#36e264")?.usingColorSpace(.sRGB)
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.redComponent,   CGFloat(0x36) / 255, accuracy: 0.005)
        XCTAssertEqual(c!.greenComponent, CGFloat(0xe2) / 255, accuracy: 0.005)
        XCTAssertEqual(c!.blueComponent,  CGFloat(0x64) / 255, accuracy: 0.005)
        // Accepts a bare (no-#) form; rejects malformed input.
        XCTAssertNotNil(EmojiAnimator.nsColor(fromHex: "36e264"))
        XCTAssertNil(EmojiAnimator.nsColor(fromHex: "nope"))
        XCTAssertNil(EmojiAnimator.nsColor(fromHex: "#12"))
    }

    func testSpawnEmojiAppliesParticipantGlowHalo() {
        let host = CALayer()
        let animator = EmojiAnimator(hostLayer: host)
        animator.spawnEmoji("❤️", glow: "#36e264")
        guard let layer = host.sublayers?.last else { XCTFail("no emoji layer added"); return }
        XCTAssertGreaterThan(layer.shadowOpacity, 0, "glow should set a visible shadow")
        XCTAssertEqual(layer.shadowColor, EmojiAnimator.nsColor(fromHex: "#36e264")?.cgColor)
    }

    func testSpawnEmojiWithoutGlowHasNoHalo() {
        let host = CALayer()
        let animator = EmojiAnimator(hostLayer: host)
        animator.spawnEmoji("❤️")   // no glow → unchanged look
        guard let layer = host.sublayers?.last else { XCTFail("no emoji layer added"); return }
        XCTAssertEqual(layer.shadowOpacity, 0, "no glow should leave the default (0) shadow opacity")
    }
}

private extension CGPath {
    func testPoints() -> [CGPoint] {
        var points: [CGPoint] = []
        applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.pointee.points[0])
            default:
                break
            }
        }
        return points
    }
}
