import AppKit
import AVFoundation
import QuartzCore

class EmojiAnimator {
    private let hostLayer: CALayer

    static let emojiSet = ["❤️", "🔥", "👏", "😂", "🤯", "💡", "☕", "✅", "❌"]

    // Image-extracted ECG beat curve (64 points, normalized x∈[0,1], y∈[-1,1], R-spike at x≈0.3465)
    private static let beatCurve: [(Double, Double)] = [
        (0.0000,0.0000), (0.0157,0.0054), (0.0315,0.0291), (0.0472,0.0560),
        (0.0630,0.0891), (0.0787,0.1258), (0.0945,0.2001), (0.1102,0.2375),
        (0.1260,0.2755), (0.1417,0.2809), (0.1575,0.2320), (0.1732,0.1614),
        (0.1890,0.0915), (0.2047,0.0496), (0.2205,-0.0438), (0.2362,-0.1079),
        (0.2520,-0.1122), (0.2677,-0.1312), (0.2835,-0.1176), (0.2992,0.0083),
        (0.3150,0.3795), (0.3307,0.7897), (0.3465,0.9132), (0.3622,0.9064),
        (0.3780,0.6096), (0.3937,0.4664), (0.4094,0.1651), (0.4252,-0.2663),
        (0.4409,-0.3111), (0.4567,-0.2185), (0.4724,-0.0557), (0.4882,-0.0400),
        (0.5039,-0.0197), (0.5197,-0.0020), (0.5354,0.0116), (0.5512,0.0062),
        (0.5669,0.0112), (0.5827,0.0196), (0.5984,0.0198), (0.6142,0.0171),
        (0.6299,0.0115), (0.6457,0.0059), (0.6614,0.0090), (0.6772,0.0005),
        (0.6929,-0.0087), (0.7087,0.0039), (0.7244,0.0185), (0.7402,0.0268),
        (0.7559,0.1190), (0.7717,0.1651), (0.7874,0.1964), (0.8031,0.2486),
        (0.8189,0.3517), (0.8346,0.3388), (0.8504,0.3551), (0.8661,0.3484),
        (0.8819,0.3192), (0.9055,0.3217), (0.9213,0.1663), (0.9370,0.1384),
        (0.9528,0.0871), (0.9685,0.0368), (0.9843,0.0190), (1.0000,-0.0000)
    ]

    // Track active toggleable effects (danger, sepia, zorro) so clicking again cancels them
    private var activeEffects: [String: CALayer] = [:]

    // Applause: persistent timer for emoji spawning
    private var applauseTimer: Timer?

    // Pulse: layers stored so clicking again can stop it
    private var pulseRunning = false
    private var _pulseDimLayer: CALayer?
    private var _pulseGridLayer: CALayer?
    private var _pulseEcgLayer: CALayer?

    init(hostLayer: CALayer) {
        self.hostLayer = hostLayer
    }

    static func soundEffect(for emoji: String) -> String? {
        let normalizedEmoji = emoji
            .replacingOccurrences(of: "\u{FE0F}", with: "")
            .replacingOccurrences(of: "\u{FE0E}", with: "")

        switch normalizedEmoji {
        case "🖥":
            return "breaking-glass.mp3"
        default:
            return nil
        }
    }

    /// Cancel a running toggleable effect. Returns true if it was running (and got cancelled).
    private func cancelIfRunning(_ key: String, sound: String? = nil) -> Bool {
        if let layer = activeEffects[key] {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
            activeEffects.removeValue(forKey: key)
            if let sound = sound {
                SoundManager.shared.stop(sound)
            }
            return true
        }
        return false
    }

    /// Register a layer as an active toggleable effect, with auto-cleanup after duration.
    private func trackEffect(_ key: String, layer: CALayer, duration: Double, sound: String? = nil) {
        activeEffects[key] = layer
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak layer] in
            guard let self = self, let layer = layer else { return }
            // Only clean up if this layer is still the active one for this key
            if self.activeEffects[key] === layer {
                self.activeEffects.removeValue(forKey: key)
            }
            layer.removeFromSuperlayer()
            if let sound = sound {
                SoundManager.shared.stop(sound)
            }
        }
    }

    func spawnEmoji(_ emoji: String = "❤️") {
        let bounds = hostLayer.bounds

        if let sound = EmojiAnimator.soundEffect(for: emoji) {
            SoundManager.shared.playOverlapping(sound, volume: 0.5)
        }

        let isScreen = emoji == "🖥️"
        let fontSize: CGFloat = isScreen ? 234 : 78
        let size: CGFloat = isScreen ? 260 : 91

        // Screen emoji: center of screen; others: bottom-left corner with ±56px random offset (30% narrower)
        let spawnX: CGFloat = isScreen ? bounds.midX : 100 + CGFloat.random(in: -56...56)
        let spawnY: CGFloat = isScreen ? bounds.height * 0.15 : 80

        let layer = CATextLayer()
        layer.string = emoji
        layer.fontSize = fontSize
        layer.alignmentMode = .center
        layer.frame = CGRect(x: spawnX - size / 2, y: spawnY, width: size, height: size)
        layer.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        hostLayer.addSublayer(layer)

        // Randomize duration: 2.5–4 seconds (matches browser host.js)
        let duration = Double.random(in: 2.5...4.0)
        let riseHeight: CGFloat = 540

        var animations: [CAAnimation] = []

        // Rise with divergent drift (picks one random direction and goes)
        let driftX = CGFloat.random(in: -50...50)
        let steps = 20
        let startPoint = layer.position

        let path = CGMutablePath()
        path.move(to: startPoint)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = startPoint.y + riseHeight * t
            let wobble = t * driftX
            path.addLine(to: CGPoint(x: startPoint.x + wobble, y: y))
        }

        let pathAnim = CAKeyframeAnimation(keyPath: "position")
        pathAnim.path = path
        pathAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animations.append(pathAnim)

        // Scale growth (1.0 → 1.3, matches browser)
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 1.3
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animations.append(scaleAnim)

        // Fade out (start fading at 40% of duration, matches browser)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.beginTime = duration * 0.4
        fadeOut.duration = duration * 0.6
        fadeOut.fillMode = .forwards
        animations.append(fadeOut)

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in
            layer?.removeFromSuperlayer()
        }
        layer.add(group, forKey: "floatAndFade")
        CATransaction.commit()
    }

    func spawnRandomEmoji() {
        spawnEmoji(EmojiAnimator.emojiSet.randomElement()!)
    }

    // MARK: - Confetti burst

    private static let confettiColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .systemPink, .systemTeal,
    ]

    // MARK: - Screen vignette effects

    /// Radial gradient vignette that pulses then fades — used for danger/success moods.
    func showVignette(key: String? = nil, color: NSColor, duration: Double = 2.5, pulses: Int = 2, soundToStop: String? = nil) {
        let bounds = hostLayer.bounds

        let vignetteLayer = CALayer()
        vignetteLayer.frame = bounds
        vignetteLayer.opacity = 0

        // Build radial gradient: transparent center → colored edges
        let gradientLayer = CAGradientLayer()
        gradientLayer.type = .radial
        gradientLayer.frame = bounds
        gradientLayer.colors = [
            NSColor.clear.cgColor,
            color.withAlphaComponent(0.0).cgColor,
            color.withAlphaComponent(0.35).cgColor,
            color.withAlphaComponent(0.7).cgColor,
        ]
        gradientLayer.locations = [0.0, 0.35, 0.7, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)

        vignetteLayer.addSublayer(gradientLayer)
        hostLayer.addSublayer(vignetteLayer)

        // Pulse in, hold, fade out
        let pulseDuration = duration / Double(pulses * 2 + 1)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0.0
        fadeIn.toValue = 1.0
        fadeIn.duration = pulseDuration
        fadeIn.autoreverses = true
        fadeIn.repeatCount = Float(pulses)

        let totalPulse = pulseDuration * 2 * Double(pulses)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 0.8
        fadeOut.toValue = 0.0
        fadeOut.beginTime = totalPulse
        fadeOut.duration = duration - totalPulse
        fadeOut.fillMode = .forwards

        let group = CAAnimationGroup()
        group.animations = [fadeIn, fadeOut]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        if let key = key {
            activeEffects[key] = vignetteLayer
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak vignetteLayer] in
            if let key = key, let self = self, self.activeEffects[key] === vignetteLayer {
                self.activeEffects.removeValue(forKey: key)
            }
            vignetteLayer?.removeFromSuperlayer()
            if let sound = soundToStop {
                SoundManager.shared.stop(sound)
            }
        }
        vignetteLayer.add(group, forKey: "vignette")
        CATransaction.commit()
    }

    func showDanger() {
        if cancelIfRunning("danger", sound: "alarm.mp3") { return }
        SoundManager.shared.play("alarm.mp3")
        showVignette(key: "danger", color: .systemRed, duration: 3.0, pulses: 3, soundToStop: "alarm.mp3")
    }

    // MARK: - Tablet-triggered alarm overlay (sound plays on tablet, not here)
    private var alarmOverlayTimer: Timer?

    func startAlarmOverlay() {
        stopAlarmOverlay()
        showVignette(key: "danger", color: .systemRed, duration: 3.0, pulses: 3)
        // Fire 200ms before cycle ends so layers overlap and avoid flicker at the seam
        alarmOverlayTimer = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: true) { [weak self] _ in
            self?.showVignette(key: "danger", color: .systemRed, duration: 3.0, pulses: 3)
        }
    }

    func stopAlarmOverlay() {
        alarmOverlayTimer?.invalidate()
        alarmOverlayTimer = nil
        _ = cancelIfRunning("danger")
    }

    // MARK: - Screen crash (screenshot shatters into broken glass shards)

    func showBrokenGlass(playSound: Bool = true) {  // formerly showEarthquake
        if playSound { SoundManager.shared.play("breaking-glass.mp3") }
        let bounds = hostLayer.bounds
        let totalDuration = 4.5

        // Capture screenshot
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first,
              let screenshot = CGDisplayCreateImage(
                  (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
              ) else { return }

        let container = CALayer()
        container.frame = bounds
        hostLayer.addSublayer(container)

        // Black background revealed as shards fall
        let blackBg = CALayer()
        blackBg.frame = bounds
        blackBg.backgroundColor = NSColor.black.cgColor
        container.addSublayer(blackBg)

        // Impact point — slightly off-center for realism
        let impact = CGPoint(
            x: bounds.width * CGFloat.random(in: 0.3...0.7),
            y: bounds.height * CGFloat.random(in: 0.3...0.7)
        )

        // Generate radial crack lines from impact to beyond screen edges
        let radialCount = Int.random(in: 14...20)
        let maxDist = sqrt(bounds.width * bounds.width + bounds.height * bounds.height)
        var radialAngles: [CGFloat] = []
        for i in 0..<radialCount {
            let baseAngle = (CGFloat(i) / CGFloat(radialCount)) * 2 * .pi
            radialAngles.append(baseAngle + CGFloat.random(in: -0.15...0.15))
        }
        radialAngles.sort()

        // For each radial line, generate points at concentric ring distances with jitter
        let ringDistances: [CGFloat] = [60, 150, 300, 500, maxDist]
        var radialPoints: [[CGPoint]] = []  // [radialIndex][ringIndex] -> point on that ray at that ring

        for angle in radialAngles {
            var points: [CGPoint] = [impact]
            for dist in ringDistances {
                let jitteredAngle = angle + CGFloat.random(in: -0.12...0.12)
                let jitteredDist = dist + CGFloat.random(in: -dist * 0.15...dist * 0.15)
                points.append(CGPoint(
                    x: impact.x + cos(jitteredAngle) * jitteredDist,
                    y: impact.y + sin(jitteredAngle) * jitteredDist
                ))
            }
            radialPoints.append(points)
        }

        // Build shard polygons: each shard is bounded by two adjacent radial lines
        // and two adjacent concentric rings
        var shardPolygons: [(path: CGPath, center: CGPoint, distFromImpact: CGFloat)] = []

        for ri in 0..<radialCount {
            let nextRi = (ri + 1) % radialCount
            for di in 0..<ringDistances.count {
                // Four corners of this shard (between ring di and di+1, between radial ri and nextRi)
                let innerDi = di
                let outerDi = di + 1
                guard outerDi < radialPoints[ri].count else { continue }

                let p1 = radialPoints[ri][innerDi]
                let p2 = radialPoints[ri][outerDi]
                let p3 = radialPoints[nextRi][outerDi]
                let p4 = radialPoints[nextRi][innerDi]

                // Add extra jagged points along the edges for irregular glass look
                let path = CGMutablePath()
                path.move(to: p1)

                // Jagged edge from p1 to p2 (along radial ri)
                let mid12 = CGPoint(
                    x: (p1.x + p2.x) / 2 + CGFloat.random(in: -15...15),
                    y: (p1.y + p2.y) / 2 + CGFloat.random(in: -15...15)
                )
                path.addLine(to: mid12)
                path.addLine(to: p2)

                // Jagged edge from p2 to p3 (along outer ring)
                let mid23 = CGPoint(
                    x: (p2.x + p3.x) / 2 + CGFloat.random(in: -12...12),
                    y: (p2.y + p3.y) / 2 + CGFloat.random(in: -12...12)
                )
                path.addLine(to: mid23)
                path.addLine(to: p3)

                // Jagged edge from p3 to p4 (along radial nextRi)
                let mid34 = CGPoint(
                    x: (p3.x + p4.x) / 2 + CGFloat.random(in: -15...15),
                    y: (p3.y + p4.y) / 2 + CGFloat.random(in: -15...15)
                )
                path.addLine(to: mid34)
                path.addLine(to: p4)

                // Jagged edge from p4 back to p1 (along inner ring)
                let mid41 = CGPoint(
                    x: (p4.x + p1.x) / 2 + CGFloat.random(in: -12...12),
                    y: (p4.y + p1.y) / 2 + CGFloat.random(in: -12...12)
                )
                path.addLine(to: mid41)
                path.closeSubpath()

                let cx = (p1.x + p2.x + p3.x + p4.x) / 4
                let cy = (p1.y + p2.y + p3.y + p4.y) / 4
                let dist = sqrt((cx - impact.x) * (cx - impact.x) + (cy - impact.y) * (cy - impact.y))

                shardPolygons.append((path: path, center: CGPoint(x: cx, y: cy), distFromImpact: dist))
            }
        }

        // Create shard layers and animate
        for shard in shardPolygons {
            let shardLayer = CALayer()
            shardLayer.frame = bounds
            shardLayer.contents = screenshot
            shardLayer.contentsGravity = .resize

            let mask = CAShapeLayer()
            mask.path = shard.path
            shardLayer.mask = mask

            let group = CALayer()
            group.frame = bounds
            group.addSublayer(shardLayer)
            container.addSublayer(group)

            // Shards near impact fall first; outer shards follow
            let normalizedDist = min(shard.distFromImpact / maxDist, 1.0)
            let holdDelay = 0.2 + Double(normalizedDist) * 1.0 + Double.random(in: 0...0.3)
            let fallDuration = Double.random(in: 0.7...1.4)

            // Fall down — use screen diagonal to account for rotation expanding shard footprint
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.byValue = -(maxDist + 300)
            fall.beginTime = CACurrentMediaTime() + holdDelay
            fall.duration = fallDuration
            fall.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fall.fillMode = .forwards
            fall.isRemovedOnCompletion = false

            // Rotate while falling
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.byValue = Double.random(in: -1.2...1.2)
            rotation.beginTime = CACurrentMediaTime() + holdDelay
            rotation.duration = fallDuration
            rotation.fillMode = .forwards
            rotation.isRemovedOnCompletion = false

            // Drift away from impact point horizontally
            let driftDir = shard.center.x > impact.x ? 1.0 : -1.0
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.byValue = CGFloat(driftDir) * CGFloat.random(in: 20...80)
            drift.beginTime = CACurrentMediaTime() + holdDelay
            drift.duration = fallDuration
            drift.fillMode = .forwards
            drift.isRemovedOnCompletion = false

            group.add(fall, forKey: "fall")
            group.add(rotation, forKey: "rotate")
            group.add(drift, forKey: "drift")
        }

        // Black screen holds, then fades out
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.beginTime = CACurrentMediaTime() + totalDuration - 0.8
        fadeOut.duration = 0.8
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        container.add(fadeOut, forKey: "fadeOut")

        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.2) { [weak container] in
            container?.removeFromSuperlayer()
        }
    }

    // MARK: - Film burn (4 black circles expanding from random positions)

    func showFilmBurn() {
        let bounds = hostLayer.bounds
        let totalDuration = 4.5

        let container = CALayer()
        container.frame = bounds
        hostLayer.addSublayer(container)

        // Max radius needed to cover the screen from any point
        let maxRadius = sqrt(bounds.width * bounds.width + bounds.height * bounds.height)

        // One circle per quadrant: TL, TR, BL, BR (random position within each quadrant)
        let halfW = bounds.width / 2
        let halfH = bounds.height / 2
        let quadrants: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, halfW, halfH, bounds.height),  // top-left
            (halfW, bounds.width, halfH, bounds.height),  // top-right
            (0, halfW, 0, halfH),              // bottom-left
            (halfW, bounds.width, 0, halfH),   // bottom-right
        ]

        for i in 0..<4 {
            let q = quadrants[i]
            let cx = CGFloat.random(in: q.0 + 20...q.1 - 20)
            let cy = CGFloat.random(in: q.2 + 20...q.3 - 20)
            let center = CGPoint(x: cx, y: cy)

            // Each circle appears within the first 1 second, staggered
            let startDelay = Double(i) * 0.25 + Double.random(in: 0...0.15)

            // Initial radius 20–100px
            let initialRadius = CGFloat.random(in: 20...100)

            // Different expansion speeds: each takes a different duration to reach max
            let expandDuration = Double.random(in: 2.5...4.0)

            let circle = CAShapeLayer()
            let initialPath = CGPath(ellipseIn: CGRect(x: center.x - initialRadius,
                                                        y: center.y - initialRadius,
                                                        width: initialRadius * 2,
                                                        height: initialRadius * 2), transform: nil)
            let finalPath = CGPath(ellipseIn: CGRect(x: center.x - maxRadius,
                                                      y: center.y - maxRadius,
                                                      width: maxRadius * 2,
                                                      height: maxRadius * 2), transform: nil)
            circle.path = initialPath
            circle.fillColor = NSColor.black.cgColor
            circle.opacity = 0
            container.addSublayer(circle)

            // Appear
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = startDelay
            appear.duration = 0.15
            appear.fillMode = .both
            appear.isRemovedOnCompletion = false

            // Expand
            let expand = CABasicAnimation(keyPath: "path")
            expand.fromValue = initialPath
            expand.toValue = finalPath
            expand.beginTime = startDelay
            expand.duration = expandDuration
            expand.timingFunction = CAMediaTimingFunction(name: .easeIn)
            expand.fillMode = .both
            expand.isRemovedOnCompletion = false

            let group = CAAnimationGroup()
            group.animations = [appear, expand]
            group.duration = totalDuration
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            circle.add(group, forKey: "burn")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.2) { [weak container] in
            container?.removeFromSuperlayer()
        }
    }

    private func spawnFireSparks(at point: CGPoint, in container: CALayer, count: Int = 15) {
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        for _ in 0..<count {
            let spark = CALayer()
            let size: CGFloat = CGFloat.random(in: 3...8)
            spark.frame = CGRect(x: point.x - size/2, y: point.y - size/2, width: size, height: size)
            spark.cornerRadius = size / 2
            let g = CGFloat.random(in: 0.2...0.6)
            spark.backgroundColor = NSColor(red: 1.0, green: g, blue: 0.0, alpha: 1.0).cgColor
            spark.contentsScale = scale
            container.addSublayer(spark)

            // Rise upward like embers
            let angle = CGFloat.random(in: CGFloat.pi * 0.15 ... CGFloat.pi * 0.85) // mostly upward
            let dist = CGFloat.random(in: 50...200)
            let endPoint = CGPoint(x: point.x + cos(angle) * dist * 0.4,
                                   y: point.y + sin(angle) * dist)

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: point)
            move.toValue = NSValue(point: endPoint)
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0

            let duration = Double.random(in: 0.5...1.2)
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak spark] in spark?.removeFromSuperlayer() }
            spark.add(group, forKey: "spark")
            CATransaction.commit()
        }
    }

    // MARK: - Zorro Z (animated fire GIF overlay)

    func showZorro() {
        if cancelIfRunning("zorro") { return }
        let bounds = hostLayer.bounds

        guard let url = Bundle.module.url(forResource: "zorro_fire", withExtension: "gif", subdirectory: "Resources"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return }

        // Extract all frames and durations
        var frames: [CGImage] = []
        var totalGifDuration: Double = 0
        for i in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(cgImage)
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any],
               let delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ??
                           gifProps[kCGImagePropertyGIFDelayTime as String] as? Double {
                totalGifDuration += delay
            } else {
                totalGifDuration += 0.05
            }
        }

        let totalDuration = totalGifDuration + 1.0

        let container = CALayer()
        container.frame = bounds
        hostLayer.addSublayer(container)

        // 85% screen width, centered, maintain aspect ratio
        let imgW = bounds.width * 0.70
        let aspectRatio = CGFloat(frames[0].height) / CGFloat(frames[0].width)
        let imgH = imgW * aspectRatio
        let imgX = (bounds.width - imgW) / 2
        let imgY = (bounds.height - imgH) / 2

        let imgLayer = CALayer()
        imgLayer.frame = CGRect(x: imgX, y: imgY, width: imgW, height: imgH)
        imgLayer.contentsGravity = .resizeAspect
        imgLayer.contents = frames[0]
        container.addSublayer(imgLayer)

        // Animate through GIF frames
        let frameAnim = CAKeyframeAnimation(keyPath: "contents")
        frameAnim.values = frames
        frameAnim.duration = totalGifDuration
        frameAnim.calculationMode = .discrete
        frameAnim.repeatCount = 1
        frameAnim.fillMode = .forwards
        frameAnim.isRemovedOnCompletion = false
        imgLayer.add(frameAnim, forKey: "gifFrames")

        // Orange glow shadow
        imgLayer.shadowColor = NSColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1.0).cgColor
        imgLayer.shadowOffset = .zero
        imgLayer.shadowRadius = 30
        imgLayer.shadowOpacity = 0.8

        let glowFlicker = CAKeyframeAnimation(keyPath: "shadowRadius")
        glowFlicker.values = [30, 40, 25, 45, 30, 35, 28]
        glowFlicker.duration = 0.25
        glowFlicker.repeatCount = .infinity
        imgLayer.add(glowFlicker, forKey: "glowFlicker")

        // Fade out
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.beginTime = CACurrentMediaTime() + totalDuration - 0.8
        fadeOut.duration = 0.8
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        container.add(fadeOut, forKey: "fadeAll")

        trackEffect("zorro", layer: container, duration: totalDuration + 0.2)
    }

    // MARK: - Fireworks

    private static let fireworkPalettes: [[NSColor]] = [
        [NSColor(red: 1, green: 0.2, blue: 0.2, alpha: 1),
         NSColor(red: 1, green: 0.5, blue: 0.1, alpha: 1),
         NSColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)],
        [NSColor(red: 0.2, green: 0.6, blue: 1, alpha: 1),
         NSColor(red: 0.4, green: 0.9, blue: 1, alpha: 1),
         .white],
        [NSColor(red: 1, green: 0.2, blue: 0.6, alpha: 1),
         NSColor(red: 0.8, green: 0.3, blue: 1, alpha: 1),
         NSColor(red: 1, green: 0.6, blue: 0.9, alpha: 1)],
        [NSColor(red: 1, green: 0.85, blue: 0.1, alpha: 1),
         .white,
         NSColor(red: 1, green: 0.95, blue: 0.6, alpha: 1)],
        [NSColor(red: 0.1, green: 1, blue: 0.4, alpha: 1),
         NSColor(red: 0.3, green: 1, blue: 0.8, alpha: 1),
         .white],
    ]

    func showFireworks(playSound: Bool = true) {
        guard activeEffects["fireworks"] == nil else { return }
        let container = CALayer()
        container.frame = hostLayer.bounds
        hostLayer.addSublayer(container)
        trackEffect("fireworks", layer: container, duration: 8.0, sound: playSound ? "fireworks.mp3" : nil)

        let bounds = hostLayer.bounds
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2.0

        // Wave 1: 3 big ones
        for r in 0..<3 {
            let delay = Double(r) * 0.4
            let x = bounds.width * (0.2 + CGFloat(r) * 0.3) + CGFloat.random(in: -60...60)
            let y = CGFloat.random(in: bounds.height * 0.50...bounds.height * 0.80)
            let palette = EmojiAnimator.fireworkPalettes.randomElement()!
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak container] in
                guard let container = container, container.superlayer != nil else { return }
                self?.launchRocket(from: CGPoint(x: x, y: -10), to: CGPoint(x: x + CGFloat.random(in: -30...30), y: y),
                                   palette: palette, scale: scale, big: true, container: container)
            }
        }
        // Wave 2: 3-4 more, staggered
        for r in 0..<Int.random(in: 3...4) {
            let delay = 1.0 + Double(r) * 0.35
            let x = CGFloat.random(in: bounds.width * 0.1...bounds.width * 0.9)
            let y = CGFloat.random(in: bounds.height * 0.40...bounds.height * 0.75)
            let palette = EmojiAnimator.fireworkPalettes.randomElement()!
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak container] in
                guard let container = container, container.superlayer != nil else { return }
                self?.launchRocket(from: CGPoint(x: x, y: -10), to: CGPoint(x: x + CGFloat.random(in: -20...20), y: y),
                                   palette: palette, scale: scale, big: Bool.random(), container: container)
            }
        }
        // Wave 3: grand finale — rapid burst of 4
        for r in 0..<4 {
            let delay = 2.5 + Double(r) * 0.15
            let x = CGFloat.random(in: bounds.width * 0.15...bounds.width * 0.85)
            let y = CGFloat.random(in: bounds.height * 0.45...bounds.height * 0.80)
            let palette = EmojiAnimator.fireworkPalettes.randomElement()!
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak container] in
                guard let container = container, container.superlayer != nil else { return }
                self?.launchRocket(from: CGPoint(x: x, y: -10), to: CGPoint(x: x, y: y),
                                   palette: palette, scale: scale, big: true, container: container)
            }
        }
    }

    private func launchRocket(from start: CGPoint, to burst: CGPoint,
                              palette: [NSColor], scale: CGFloat, big: Bool, container: CALayer) {
        let riseDuration = Double.random(in: 0.4...0.7)

        // Rocket — bright streak rising up
        let rocket = CAShapeLayer()
        let trailPath = CGMutablePath()
        trailPath.move(to: start)
        trailPath.addLine(to: CGPoint(x: start.x, y: start.y + 40))
        rocket.path = trailPath
        rocket.strokeColor = NSColor.white.cgColor
        rocket.lineWidth = 3
        rocket.lineCap = .round
        rocket.fillColor = nil
        rocket.shadowColor = palette[0].cgColor
        rocket.shadowOffset = .zero
        rocket.shadowRadius = 12
        rocket.shadowOpacity = 1.0
        container.addSublayer(rocket)

        // Rise animation
        let risePath = CGMutablePath()
        risePath.move(to: start)
        // Slight wobble on the way up
        let midX = (start.x + burst.x) / 2 + CGFloat.random(in: -15...15)
        let midY = (start.y + burst.y) / 2
        risePath.addQuadCurve(to: burst, control: CGPoint(x: midX, y: midY))

        let riseAnim = CAKeyframeAnimation(keyPath: "position")
        riseAnim.path = risePath
        riseAnim.duration = riseDuration
        riseAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        riseAnim.fillMode = .forwards
        riseAnim.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak rocket, weak container] in
            rocket?.removeFromSuperlayer()
            guard let container = container, container.superlayer != nil else { return }
            self?.explodeFirework(at: burst, palette: palette, scale: scale, big: big, container: container)
        }
        rocket.add(riseAnim, forKey: "rise")
        CATransaction.commit()
    }

    private func explodeFirework(at center: CGPoint, palette: [NSColor], scale: CGFloat, big: Bool, container: CALayer) {
        let streakCount = big ? Int.random(in: 40...55) : Int.random(in: 24...32)
        let burstRadius = big ? CGFloat.random(in: 250...400) : CGFloat.random(in: 140...220)
        let duration = big ? Double.random(in: 1.8...2.5) : Double.random(in: 1.2...1.8)

        // Massive flash
        let flash = CALayer()
        let flashSize: CGFloat = big ? 120 : 60
        flash.frame = CGRect(x: center.x - flashSize/2, y: center.y - flashSize/2,
                              width: flashSize, height: flashSize)
        flash.cornerRadius = flashSize / 2
        flash.backgroundColor = NSColor.white.cgColor
        flash.shadowColor = palette[0].cgColor
        flash.shadowOffset = .zero
        flash.shadowRadius = big ? 80 : 40
        flash.shadowOpacity = 1.0
        flash.contentsScale = scale
        container.addSublayer(flash)

        let flashScale = CABasicAnimation(keyPath: "transform.scale")
        flashScale.fromValue = 0.5
        flashScale.toValue = big ? 3.0 : 2.0

        let flashFade = CABasicAnimation(keyPath: "opacity")
        flashFade.fromValue = 1.0
        flashFade.toValue = 0.0

        let flashGroup = CAAnimationGroup()
        flashGroup.animations = [flashScale, flashFade]
        flashGroup.duration = 0.3
        flashGroup.fillMode = .forwards
        flashGroup.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak flash] in flash?.removeFromSuperlayer() }
        flash.add(flashGroup, forKey: "flash")
        CATransaction.commit()

        // Streaking lines — the real firework effect
        for i in 0..<streakCount {
            let baseAngle = (CGFloat(i) / CGFloat(streakCount)) * 2 * .pi
            let angle = baseAngle + CGFloat.random(in: -0.12...0.12)
            let dist = burstRadius * CGFloat.random(in: 0.6...1.0)
            let color = palette.randomElement()!

            // Each streak is a line (CAShapeLayer) that extends outward
            let endPoint = CGPoint(
                x: center.x + cos(angle) * dist,
                y: center.y + sin(angle) * dist
            )
            // Gravity droop at the end
            let droopEnd = CGPoint(x: endPoint.x, y: endPoint.y - dist * 0.25)

            let streakPath = CGMutablePath()
            streakPath.move(to: center)
            streakPath.addQuadCurve(to: droopEnd,
                                     control: endPoint)

            let streak = CAShapeLayer()
            streak.path = streakPath
            streak.strokeColor = color.cgColor
            streak.lineWidth = big ? CGFloat.random(in: 2.5...4.5) : CGFloat.random(in: 1.5...3.0)
            streak.lineCap = .round
            streak.fillColor = nil
            streak.shadowColor = color.cgColor
            streak.shadowOffset = .zero
            streak.shadowRadius = big ? 8 : 4
            streak.shadowOpacity = 1.0
            streak.strokeEnd = 0
            container.addSublayer(streak)

            // Draw the streak outward rapidly
            let drawDuration = duration * 0.35
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = drawDuration
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            draw.fillMode = .forwards
            draw.isRemovedOnCompletion = false

            // Then the tail follows (strokeStart catches up)
            let tail = CABasicAnimation(keyPath: "strokeStart")
            tail.fromValue = 0
            tail.toValue = 1
            tail.beginTime = drawDuration * 0.4
            tail.duration = duration - drawDuration * 0.4
            tail.timingFunction = CAMediaTimingFunction(name: .easeIn)
            tail.fillMode = .forwards
            tail.isRemovedOnCompletion = false

            // Fade at the end
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.beginTime = duration * 0.5
            fade.duration = duration * 0.5
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false

            let group = CAAnimationGroup()
            group.animations = [draw, tail, fade]
            group.duration = duration
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak streak] in streak?.removeFromSuperlayer() }
            streak.add(group, forKey: "burst")
            CATransaction.commit()

            // Glowing dot at the tip of each streak
            if i % 2 == 0 {
                let dot = CALayer()
                let dotSize: CGFloat = big ? 6 : 4
                dot.frame = CGRect(x: center.x - dotSize/2, y: center.y - dotSize/2,
                                    width: dotSize, height: dotSize)
                dot.cornerRadius = dotSize / 2
                dot.backgroundColor = NSColor.white.cgColor
                dot.shadowColor = color.cgColor
                dot.shadowOffset = .zero
                dot.shadowRadius = 6
                dot.shadowOpacity = 1.0
                dot.contentsScale = scale
                container.addSublayer(dot)

                let dotPath = CGMutablePath()
                dotPath.move(to: center)
                dotPath.addQuadCurve(to: droopEnd, control: endPoint)

                let dotMove = CAKeyframeAnimation(keyPath: "position")
                dotMove.path = dotPath
                dotMove.timingFunction = CAMediaTimingFunction(name: .easeOut)

                let dotFade = CABasicAnimation(keyPath: "opacity")
                dotFade.fromValue = 1.0
                dotFade.toValue = 0.0
                dotFade.beginTime = duration * 0.4
                dotFade.duration = duration * 0.6
                dotFade.fillMode = .forwards

                let dotShrink = CABasicAnimation(keyPath: "transform.scale")
                dotShrink.fromValue = 1.5
                dotShrink.toValue = 0.2
                dotShrink.timingFunction = CAMediaTimingFunction(name: .easeIn)

                let dotGroup = CAAnimationGroup()
                dotGroup.animations = [dotMove, dotFade, dotShrink]
                dotGroup.duration = duration
                dotGroup.fillMode = .forwards
                dotGroup.isRemovedOnCompletion = false

                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak dot] in dot?.removeFromSuperlayer() }
                dot.add(dotGroup, forKey: "tip")
                CATransaction.commit()
            }
        }

        // Secondary crackle sparks — tiny pops after main burst
        if big {
            for j in 0..<8 {
                let sparkDelay = Double.random(in: 0.3...1.0)
                let sparkCenter = CGPoint(
                    x: center.x + CGFloat.random(in: -burstRadius * 0.5...burstRadius * 0.5),
                    y: center.y + CGFloat.random(in: -burstRadius * 0.3...burstRadius * 0.5)
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + sparkDelay) { [weak container] in
                    guard let container = container, container.superlayer != nil else { return }
                    let color = palette.randomElement()!
                    for _ in 0..<6 {
                        let spark = CALayer()
                        let sz: CGFloat = CGFloat.random(in: 2...4)
                        spark.frame = CGRect(x: sparkCenter.x, y: sparkCenter.y, width: sz, height: sz)
                        spark.cornerRadius = sz / 2
                        spark.backgroundColor = color.cgColor
                        spark.contentsScale = scale
                        container.addSublayer(spark)

                        let ang = CGFloat.random(in: 0...(2 * .pi))
                        let d = CGFloat.random(in: 20...50)
                        let end = CGPoint(x: sparkCenter.x + cos(ang) * d,
                                          y: sparkCenter.y + sin(ang) * d - 15)
                        let move = CABasicAnimation(keyPath: "position")
                        move.toValue = NSValue(point: end)
                        let fade = CABasicAnimation(keyPath: "opacity")
                        fade.fromValue = 1.0
                        fade.toValue = 0.0
                        let g = CAAnimationGroup()
                        g.animations = [move, fade]
                        g.duration = Double.random(in: 0.3...0.6)
                        g.fillMode = .forwards
                        g.isRemovedOnCompletion = false
                        CATransaction.begin()
                        CATransaction.setCompletionBlock { [weak spark] in spark?.removeFromSuperlayer() }
                        spark.add(g, forKey: "crackle")
                        CATransaction.commit()
                    }
                    _ = j // suppress warning
                }
            }
        }
    }

    // MARK: - Sepia / old film overlay

    func showSepia(playSound: Bool = true) {
        let soundKey: String? = playSound ? "projector.mp3" : nil
        if cancelIfRunning("sepia", sound: soundKey) { return }
        let bounds = hostLayer.bounds
        let totalDuration = 7.0

        if playSound {
            SoundManager.shared.play("projector.mp3")
        }

        let container = CALayer()
        container.frame = bounds
        hostLayer.addSublayer(container)

        // Warm sepia wash — visible yellowed center
        let sepiaLayer = CALayer()
        sepiaLayer.frame = bounds
        sepiaLayer.backgroundColor = NSColor(red: 0.50, green: 0.38, blue: 0.15, alpha: 0.45).cgColor
        sepiaLayer.opacity = 0
        container.addSublayer(sepiaLayer)

        // Vignette darkening at edges (keeps center visible/yellowed)
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.frame = bounds
        vignette.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor(white: 0, alpha: 0.45).cgColor,
            NSColor(white: 0, alpha: 0.75).cgColor,
        ]
        vignette.locations = [0.0, 0.35, 0.70, 1.0]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1.0, y: 1.0)
        vignette.opacity = 0
        container.addSublayer(vignette)

        // Film grain — flickering specks
        let grainLayer = CALayer()
        grainLayer.frame = bounds
        grainLayer.opacity = 0
        container.addSublayer(grainLayer)

        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        for _ in 0..<60 {
            let speck = CALayer()
            let sz = CGFloat.random(in: 1.5...4)
            speck.frame = CGRect(
                x: CGFloat.random(in: 0...bounds.width),
                y: CGFloat.random(in: 0...bounds.height),
                width: sz, height: sz
            )
            speck.cornerRadius = sz / 2
            let bright = Bool.random() ? CGFloat.random(in: 0.8...1.0) : CGFloat.random(in: 0...0.15)
            speck.backgroundColor = NSColor(white: bright, alpha: CGFloat.random(in: 0.3...0.7)).cgColor
            speck.contentsScale = scale
            grainLayer.addSublayer(speck)

            let flicker = CAKeyframeAnimation(keyPath: "opacity")
            flicker.values = [1.0, 0.0, 1.0, 0.0, 0.7, 0.0, 1.0]
            flicker.duration = Double.random(in: 0.15...0.4)
            flicker.repeatCount = .infinity
            speck.add(flicker, forKey: "flicker")
        }

        // Vertical scratches — thick and visible
        for _ in 0..<8 {
            let scratch = CAShapeLayer()
            let sp = CGMutablePath()
            let x = CGFloat.random(in: bounds.width * 0.05...bounds.width * 0.95)
            sp.move(to: CGPoint(x: x + CGFloat.random(in: -3...3), y: 0))
            sp.addLine(to: CGPoint(x: x + CGFloat.random(in: -8...8), y: bounds.height))
            scratch.path = sp
            scratch.strokeColor = NSColor(white: 0.95, alpha: 0.6).cgColor
            scratch.lineWidth = CGFloat.random(in: 1.5...4.0)
            scratch.fillColor = nil
            scratch.opacity = 0
            container.addSublayer(scratch)

            let sf = CAKeyframeAnimation(keyPath: "opacity")
            sf.values = [0, 0, 0.8, 0, 0, 0.6, 0, 0]
            sf.duration = Double.random(in: 0.2...0.5)
            sf.repeatCount = .infinity
            scratch.add(sf, forKey: "scratch")
        }

        // Fade in over 1s, hold throughout, fade out in last 1s
        let fadeInEnd = 1.0 / totalDuration
        let fadeOutStart = 1.0 - (1.0 / totalDuration)

        for layer in [sepiaLayer, vignette, grainLayer] {
            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = [0.0, 1.0, 1.0, 0.0]
            anim.keyTimes = [0.0, NSNumber(value: fadeInEnd),
                             NSNumber(value: fadeOutStart), 1.0]
            anim.duration = totalDuration
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "sepia")
        }

        // Projector jitter — gentle throughout
        let jitter = CAKeyframeAnimation(keyPath: "position")
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var jitterValues: [NSValue] = []
        for _ in 0..<100 {
            jitterValues.append(NSValue(point: CGPoint(
                x: c.x + CGFloat.random(in: -1.5...1.5),
                y: c.y + CGFloat.random(in: -1.5...1.5)
            )))
        }
        jitter.values = jitterValues
        jitter.duration = totalDuration
        container.add(jitter, forKey: "jitter")

        trackEffect("sepia", layer: container, duration: totalDuration + 0.2, sound: soundKey)
    }

    // MARK: - Confetti burst

    func spawnConfetti(count: Int = 80) {
        SoundManager.shared.playOverlapping("confetti.mp3")
        let bounds = hostLayer.bounds
        let screenW = bounds.width
        let screenH = bounds.height
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2.0

        for i in 0..<count {
            let delay = Double(i) * 0.012 // stagger over ~1s

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }

                let color = EmojiAnimator.confettiColors.randomElement()!
                let layer = CALayer()

                // Larger confetti pieces
                let w = CGFloat.random(in: 14...26)
                let h = CGFloat.random(in: 8...26)
                let startX = CGFloat.random(in: 0...screenW)
                let startY = screenH + 20 // start above top edge

                layer.frame = CGRect(x: startX, y: startY, width: w, height: h)
                layer.backgroundColor = color.cgColor
                layer.cornerRadius = Bool.random() ? w / 2 : 1 // round or rectangular
                layer.contentsScale = scale
                self.hostLayer.addSublayer(layer)

                let duration = Double.random(in: 2.5...4.5)

                // Fall down with horizontal drift
                let endY: CGFloat = -30
                let drift = CGFloat.random(in: -200...200)

                let path = CGMutablePath()
                let start = layer.position
                let end = CGPoint(x: start.x + drift, y: endY)
                let cp1 = CGPoint(x: start.x + drift * 0.3 + CGFloat.random(in: -80...80),
                                  y: start.y - (start.y - endY) * 0.3)
                let cp2 = CGPoint(x: end.x + CGFloat.random(in: -60...60),
                                  y: start.y - (start.y - endY) * 0.7)
                path.move(to: start)
                path.addCurve(to: end, control1: cp1, control2: cp2)

                let pathAnim = CAKeyframeAnimation(keyPath: "position")
                pathAnim.path = path
                pathAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)

                // Spin
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = Double.random(in: -6...6) * .pi

                // Fade near end
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0
                fade.toValue = 0.0
                fade.beginTime = duration * 0.6
                fade.duration = duration * 0.4
                fade.fillMode = .forwards

                let group = CAAnimationGroup()
                group.animations = [pathAnim, spin, fade]
                group.duration = duration
                group.fillMode = .forwards
                group.isRemovedOnCompletion = false

                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak layer] in
                    layer?.removeFromSuperlayer()
                }
                layer.add(group, forKey: "confetti")
                CATransaction.commit()
            }
        }
    }

    // MARK: - Applause (toggleable: click to start, click again to stop)

    func showApplause(playSound: Bool = true) {
        guard applauseTimer == nil else { return }   // already running — ignore

        if playSound { SoundManager.shared.play("applause.mp3") }
        let duration = 6.0

        // Initial burst, then steady stream
        for i in 0..<10 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { [weak self] in self?.spawnApplauseClap() } }
        applauseTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.spawnApplauseClap()
        }

        // Auto-stop after duration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.applauseTimer?.invalidate()
            self?.applauseTimer = nil
            SoundManager.shared.stop("applause.mp3")
        }
    }

    func stopApplause() {
        applauseTimer?.invalidate()
        applauseTimer = nil
        SoundManager.shared.stop("applause.mp3")
    }

    private func spawnApplauseClap() {
        let bounds = hostLayer.bounds
        let isBig = Int.random(in: 0..<4) == 0   // ~25% chance of giant clap
        let size: CGFloat = isBig ? CGFloat.random(in: 108...216) : CGFloat.random(in: 36...72)
        // Spawn from random position across the bottom third, fly upward
        let spawnX = CGFloat.random(in: size ... bounds.width - size)
        let spawnY = CGFloat.random(in: 0 ... bounds.height * 0.35)

        let layer = CATextLayer()
        layer.string = "👏"
        layer.fontSize = size * 0.8
        layer.alignmentMode = .center
        layer.frame = CGRect(x: spawnX - size / 2, y: spawnY, width: size, height: size)
        layer.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        hostLayer.addSublayer(layer)

        let duration = Double.random(in: 1.8...2.8)
        let riseHeight = bounds.height * CGFloat.random(in: 0.55...0.85)
        let drift = CGFloat.random(in: -80...80)

        // Rise path with wobble
        let path = CGMutablePath()
        let steps = 12
        let start = CGPoint(x: spawnX, y: spawnY + size / 2)
        path.move(to: start)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let wobble = sin(t * 3 * .pi) * 20 * (1 - t)
            path.addLine(to: CGPoint(x: start.x + drift * t + wobble, y: start.y + riseHeight * t))
        }

        let pathAnim = CAKeyframeAnimation(keyPath: "position")
        pathAnim.path = path
        pathAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.6
        scaleAnim.toValue = 1.1

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.beginTime = duration * 0.45
        fadeOut.duration = duration * 0.55
        fadeOut.fillMode = .forwards

        let group = CAAnimationGroup()
        group.animations = [pathAnim, scaleAnim, fadeOut]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in layer?.removeFromSuperlayer() }
        layer.add(group, forKey: "applauseClap")
        CATransaction.commit()
    }

    // MARK: - Pulse / heartbeat (one-shot: 2 QRS cycles then flatline)

    func showPulse(playSound: Bool = false) {
        if pulseRunning { _stopPulse(); return }
        pulseRunning = true
        if playSound { SoundManager.shared.play("flatline.mp3") }

        let bounds = hostLayer.bounds
        // Timing: dying.mp3 R-spikes at 0.105s and 1.507s. Image peaks at 22% and 48% of width.
        // totalDuration: interval 26% of width must match audio interval 1.402s → 1.402/0.26=5.392s
        // soundDelay=1.081s: audio starts 1.081s after reveal →
        //   beat1 visual at 0.22*5.392=1.186s = audio beat1 at 1.081+0.105=1.186s ✓
        //   beat2 visual at 0.48*5.392=2.588s = audio beat2 at 1.081+1.507=2.588s ✓ (0ms error)
        let totalDuration: Double = 5.392
        let soundDelay:    Double = 1.081

        // Dark overlay
        let dimLayer = CALayer()
        _pulseDimLayer = dimLayer
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor(white: 0, alpha: 0.50).cgColor
        dimLayer.opacity = 0
        hostLayer.addSublayer(dimLayer)

        // Fade in overlay
        let dimIn = CABasicAnimation(keyPath: "opacity")
        dimIn.fromValue = 0
        dimIn.toValue = 1
        dimIn.duration = 0.5
        dimIn.fillMode = .forwards
        dimIn.isRemovedOnCompletion = false
        dimLayer.add(dimIn, forKey: "dimIn")

        // EKG graph-paper grid (green, between dark overlay and ECG line)
        let gridContainer = CALayer()
        _pulseGridLayer = gridContainer
        gridContainer.frame = bounds
        gridContainer.opacity = 0
        hostLayer.addSublayer(gridContainer)

        let minorSpacing: CGFloat = 20
        let majorEvery: Int = 5
        let minorPath = CGMutablePath()
        let majorPath = CGMutablePath()

        var xi = 0; var x: CGFloat = 0
        while x <= bounds.width {
            if xi % majorEvery == 0 { majorPath.move(to: CGPoint(x: x, y: 0)); majorPath.addLine(to: CGPoint(x: x, y: bounds.height)) }
            else                    { minorPath.move(to: CGPoint(x: x, y: 0)); minorPath.addLine(to: CGPoint(x: x, y: bounds.height)) }
            x += minorSpacing; xi += 1
        }
        var yi = 0; var y: CGFloat = 0
        while y <= bounds.height {
            if yi % majorEvery == 0 { majorPath.move(to: CGPoint(x: 0, y: y)); majorPath.addLine(to: CGPoint(x: bounds.width, y: y)) }
            else                    { minorPath.move(to: CGPoint(x: 0, y: y)); minorPath.addLine(to: CGPoint(x: bounds.width, y: y)) }
            y += minorSpacing; yi += 1
        }

        let minorGrid = CAShapeLayer()
        minorGrid.path = minorPath
        minorGrid.strokeColor = NSColor(red: 0.0, green: 0.8, blue: 0.35, alpha: 0.10).cgColor
        minorGrid.lineWidth = 0.5
        minorGrid.fillColor = nil
        gridContainer.addSublayer(minorGrid)

        let majorGrid = CAShapeLayer()
        majorGrid.path = majorPath
        majorGrid.strokeColor = NSColor(red: 0.0, green: 0.8, blue: 0.35, alpha: 0.24).cgColor
        majorGrid.lineWidth = 1.0
        majorGrid.fillColor = nil
        gridContainer.addSublayer(majorGrid)

        let gridIn = CABasicAnimation(keyPath: "opacity")
        gridIn.fromValue = 0; gridIn.toValue = 1
        gridIn.duration = 0.5
        gridIn.fillMode = .forwards; gridIn.isRemovedOnCompletion = false
        gridContainer.add(gridIn, forKey: "gridIn")

        // ECG canvas — full screen (amplitude needs full height)
        // Load the extracted ECG image (green line, transparent background)
        guard let url = Bundle.module.url(forResource: "ecg_line", withExtension: "png", subdirectory: "Resources"),
              let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            pulseRunning = false
            return
        }

        let ecgLayer = CALayer()
        _pulseEcgLayer = ecgLayer
        ecgLayer.contents = cgImage
        ecgLayer.contentsGravity = .resize   // stretch to fill frame completely
        ecgLayer.frame = bounds
        ecgLayer.opacity = 0
        hostLayer.addSublayer(ecgLayer)

        // Fade in image
        let ecgFadeIn = CABasicAnimation(keyPath: "opacity")
        ecgFadeIn.fromValue = 0
        ecgFadeIn.toValue = 1
        ecgFadeIn.duration = 0.5
        ecgFadeIn.fillMode = .forwards
        ecgFadeIn.isRemovedOnCompletion = false
        ecgLayer.add(ecgFadeIn, forKey: "ecgFadeIn")

        // Left-to-right reveal mask (white rect grows from left edge)
        let maskLayer = CALayer()
        maskLayer.backgroundColor = NSColor.white.cgColor
        maskLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        maskLayer.position = CGPoint(x: 0, y: bounds.height / 2)
        maskLayer.bounds = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
        ecgLayer.mask = maskLayer

        let reveal = CABasicAnimation(keyPath: "bounds.size.width")
        reveal.fromValue = 0
        reveal.toValue = bounds.width
        reveal.duration = totalDuration
        reveal.timingFunction = CAMediaTimingFunction(name: .linear)
        reveal.fillMode = .forwards
        reveal.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak dimLayer, weak gridContainer, weak ecgLayer] in
            // Model opacity is still 0 (forward-filled anim keeps presentation at 1).
            // Use explicit CABasicAnimation fromValue:1 so Core Animation sees a real change.
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                dimLayer?.removeFromSuperlayer()
                gridContainer?.removeFromSuperlayer()
                ecgLayer?.removeFromSuperlayer()
                self?.pulseRunning = false
                self?._pulseDimLayer = nil
                self?._pulseGridLayer = nil
                self?._pulseEcgLayer = nil
            }
            for layer in [dimLayer, gridContainer, ecgLayer].compactMap({ $0 }) {
                let fadeOut = CABasicAnimation(keyPath: "opacity")
                fadeOut.fromValue = 1; fadeOut.toValue = 0
                fadeOut.duration = 0.5
                fadeOut.fillMode = .forwards; fadeOut.isRemovedOnCompletion = false
                layer.add(fadeOut, forKey: "fadeOut")
            }
            CATransaction.commit()
        }
        maskLayer.add(reveal, forKey: "reveal")
        CATransaction.commit()

    }

    // MARK: - Sketched Heart (crayon pencil style, right half first then left half)

    func showSketchedHeart() {
        let bounds = hostLayer.bounds
        let cx = bounds.midX
        let hcy = bounds.midY + bounds.height * 0.03
        let r: CGFloat = min(bounds.width, bounds.height) * 0.38

        let drawHalf: Double = 0.72      // seconds to draw each half
        let holdTime: Double = 1.8
        let fadeDuration: Double = 1.0

        let container = CALayer()
        container.frame = bounds
        hostLayer.addSublayer(container)

        // Heart geometry (CALayer coords: y increases upward)
        let topDip    = CGPoint(x: cx,       y: hcy + r * 0.18)
        let rightmost = CGPoint(x: cx + r,   y: hcy)
        let bottomTip = CGPoint(x: cx,       y: hcy - r * 1.10)
        let leftmost  = CGPoint(x: cx - r,   y: hcy)

        // Right half: top-dip → right-arc → bottom-tip
        let rightPath = CGMutablePath()
        rightPath.move(to: topDip)
        rightPath.addCurve(to: rightmost,
            control1: CGPoint(x: cx + r * 0.28, y: hcy + r * 0.62),
            control2: CGPoint(x: cx + r * 0.88, y: hcy + r * 0.48))
        rightPath.addCurve(to: bottomTip,
            control1: CGPoint(x: cx + r * 0.98, y: hcy - r * 0.42),
            control2: CGPoint(x: cx + r * 0.22, y: hcy - r * 1.10))

        // Left half: bottom-tip → left-arc → top-dip (mirror)
        let leftPath = CGMutablePath()
        leftPath.move(to: bottomTip)
        leftPath.addCurve(to: leftmost,
            control1: CGPoint(x: cx - r * 0.22, y: hcy - r * 1.10),
            control2: CGPoint(x: cx - r * 0.98, y: hcy - r * 0.42))
        leftPath.addCurve(to: topDip,
            control1: CGPoint(x: cx - r * 0.88, y: hcy + r * 0.48),
            control2: CGPoint(x: cx - r * 0.28, y: hcy + r * 0.62))

        // Crayon stroke layers — multiple slightly offset strokes create the pencil texture
        struct StrokeDef {
            let width: CGFloat; let opacity: Float; let dx: CGFloat; let dy: CGFloat
            let r: CGFloat; let g: CGFloat; let b: CGFloat
            let shadowRadius: CGFloat
        }
        let strokeDefs: [StrokeDef] = [
            // Soft outer glow
            StrokeDef(width: 32, opacity: 0.10, dx:  0,  dy:  0, r: 0.90, g: 0.08, b: 0.08, shadowRadius: 18),
            // Main rough strokes — slightly offset for crayon look
            StrokeDef(width: 20, opacity: 0.82, dx:  2,  dy: -1, r: 0.76, g: 0.05, b: 0.05, shadowRadius: 0),
            StrokeDef(width: 18, opacity: 0.65, dx: -2,  dy:  2, r: 0.68, g: 0.04, b: 0.04, shadowRadius: 0),
            StrokeDef(width: 14, opacity: 0.50, dx:  1,  dy:  3, r: 0.82, g: 0.06, b: 0.06, shadowRadius: 0),
            // Fine bright edge (gives the "fresh pencil" shine)
            StrokeDef(width:  8, opacity: 0.40, dx: -1,  dy: -2, r: 0.94, g: 0.20, b: 0.20, shadowRadius: 0),
        ]

        let now = CACurrentMediaTime()

        for (halfIdx, path) in [(rightPath as CGPath), (leftPath as CGPath)].enumerated() {
            let halfBegin = now + Double(halfIdx) * drawHalf
            for def in strokeDefs {
                let sl = CAShapeLayer()
                sl.path = path
                sl.strokeColor = NSColor(red: def.r, green: def.g, blue: def.b, alpha: 1.0).cgColor
                sl.fillColor = nil
                sl.lineWidth = def.width
                sl.lineCap = .round
                sl.lineJoin = .round
                sl.strokeEnd = 0
                sl.opacity = 0
                if def.dx != 0 || def.dy != 0 {
                    sl.setAffineTransform(CGAffineTransform(translationX: def.dx, y: def.dy))
                }
                if def.shadowRadius > 0 {
                    sl.shadowColor = NSColor(red: def.r, green: def.g, blue: def.b, alpha: 1.0).cgColor
                    sl.shadowOffset = .zero
                    sl.shadowRadius = def.shadowRadius
                    sl.shadowOpacity = 0.7
                }
                container.addSublayer(sl)

                // Draw stroke
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0; draw.toValue = 1
                draw.beginTime = halfBegin
                draw.duration = drawHalf
                draw.timingFunction = CAMediaTimingFunction(name: .linear)
                draw.fillMode = .both
                draw.isRemovedOnCompletion = false
                sl.add(draw, forKey: "draw")

                // Fade in as drawing starts
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0; fadeIn.toValue = def.opacity
                fadeIn.beginTime = halfBegin
                fadeIn.duration = drawHalf * 0.25
                fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fadeIn.fillMode = .both
                fadeIn.isRemovedOnCompletion = false
                sl.add(fadeIn, forKey: "reveal")
            }
        }

        // Fade out entire container after hold
        let fadeBegin = now + drawHalf * 2 + holdTime
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1; fadeOut.toValue = 0
        fadeOut.beginTime = fadeBegin
        fadeOut.duration = fadeDuration
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak container] in
            container?.removeFromSuperlayer()
        }
        container.add(fadeOut, forKey: "fadeOut")
        CATransaction.commit()
    }

    // MARK: - Fear

    func showFear(playSound: Bool = true) {
        if playSound { SoundManager.shared.play("scream_man.mp3") }
        let bounds = hostLayer.bounds
        let duration: Double = 1.75
        let fontSize: CGFloat = 100
        let size: CGFloat = 120

        // Spawn at 20% from left, 20% from bottom; rise to marked target (63%, 63%)
        let startX = bounds.width * 0.20
        let startY = bounds.height * 0.20
        let endX = bounds.width * 0.63
        let endY = bounds.height * 0.63

        let layer = CATextLayer()
        layer.string = "😱"
        layer.fontSize = fontSize
        layer.alignmentMode = .center
        layer.frame = CGRect(x: startX - size / 2, y: startY - size / 2, width: size, height: size)
        layer.contentsScale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        hostLayer.addSublayer(layer)

        // Position: linear drift from spawn to screen center
        let pathAnim = CAKeyframeAnimation(keyPath: "position")
        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: startY))
        path.addLine(to: CGPoint(x: endX, y: endY))
        pathAnim.path = path
        pathAnim.timingFunction = CAMediaTimingFunction(name: .linear)

        // Scale: linear, reaching 300% of screen height at end
        let finalScale = 3.0 * bounds.height / size
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = finalScale
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .linear)

        // Fade to 20% opacity across full duration
        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 1.0
        fadeAnim.toValue = 0.0
        fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let group = CAAnimationGroup()
        group.animations = [pathAnim, scaleAnim, fadeAnim]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in layer?.removeFromSuperlayer() }
        layer.add(group, forKey: "fear")
        CATransaction.commit()
    }

    // MARK: - Explosion GIF overlay

    func showExplosionGif(playSound: Bool = true) {
        guard activeEffects["explosion"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?._showExplosionGif(playSound: playSound) }
    }

    private func _showExplosionGif(playSound: Bool = true) {
        guard activeEffects["explosion"] == nil else { return }
        guard let url = Bundle.module.url(forResource: "explosion", withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return }

        var images: [CGImage] = []
        var totalDuration: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(cg)
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gif  = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = gif?[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.1
            totalDuration += delay
        }

        let size = min(hostLayer.bounds.width, hostLayer.bounds.height) * 1.2
        let x = (hostLayer.bounds.width - size) / 2
        let y = (hostLayer.bounds.height - size) / 2 + hostLayer.bounds.height / 6 - hostLayer.bounds.height * 0.1

        let gifLayer = CALayer()
        gifLayer.frame = CGRect(x: x, y: y, width: size, height: size)
        gifLayer.contentsGravity = .resizeAspect
        if let first = images.first { gifLayer.contents = first }
        hostLayer.addSublayer(gifLayer)
        if playSound { SoundManager.shared.play("explosion.mp3") }
        trackEffect("explosion", layer: gifLayer, duration: totalDuration)

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = images
        anim.duration = totalDuration
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak gifLayer] in gifLayer?.removeFromSuperlayer() }
        gifLayer.add(anim, forKey: "explosionFrames")
        CATransaction.commit()
    }

    // MARK: - Game Over overlay

    func showGameOver(playSound: Bool = true) {
        guard activeEffects["game-over"] == nil else { return }
        let bounds = hostLayer.bounds

        // Match tablet sound duration
        var duration: Double = 8.0
        if let soundURL = Bundle.module.url(forResource: "dying", withExtension: "mp3") {
            let asset = AVURLAsset(url: soundURL)
            let d = asset.duration
            if d.isNumeric { duration = CMTimeGetSeconds(d) }
        }

        let container = CALayer()
        container.frame = bounds
        hostLayer.addSublayer(container)
        trackEffect("game-over", layer: container, duration: duration, sound: playSound ? "dying.mp3" : nil)
        if playSound { SoundManager.shared.play("dying.mp3") }

        // 70% black backdrop
        let blackLayer = CALayer()
        blackLayer.frame = bounds
        blackLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        container.addSublayer(blackLayer)

        // Game Over image centered — PNG with transparent background
        if let url = Bundle.module.url(forResource: "game-over", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            let imgW = bounds.width * 0.7
            let imgH = imgW * (img.size.height / img.size.width)
            let imgLayer = CALayer()
            imgLayer.frame = CGRect(x: (bounds.width - imgW) / 2,
                                    y: (bounds.height - imgH) / 2,
                                    width: imgW, height: imgH)
            imgLayer.contents = img
            imgLayer.contentsGravity = .resizeAspect
            container.addSublayer(imgLayer)
        }
        // Overlay disappears abruptly via trackEffect after duration — no fade
    }

    // MARK: - Fail overlay (latest PNG from ~/Downloads, centered, 50% screen height)

    func showFail(playSound: Bool = true) {
        guard activeEffects["fail"] == nil else { return }
        let bounds = hostLayer.bounds
        let duration: Double = 3.2  // matches fail.mp3 (~3.21s on tablet)

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"))
        let url = downloadsURL.appendingPathComponent("pngtree-fail-stamp-cleaned.png")
        guard let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 else {
            overlayInfo("showFail: failed to load pngtree-fail-stamp-cleaned.png")
            return
        }

        let imgH = bounds.height * 1.0
        let imgW = imgH * (img.size.width / img.size.height)
        let imgLayer = CALayer()
        imgLayer.frame = CGRect(x: (bounds.width - imgW) / 2,
                                y: (bounds.height - imgH) / 2,
                                width: imgW, height: imgH)
        imgLayer.contents = img
        imgLayer.contentsGravity = .resizeAspect
        hostLayer.addSublayer(imgLayer)
        trackEffect("fail", layer: imgLayer, duration: duration, sound: playSound ? "fail.mp3" : nil)
        if playSound { SoundManager.shared.play("fail.mp3") }

        // Fade out over the last 0.3s
        let fadeStart = max(0, duration - 0.3)
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.beginTime = CACurrentMediaTime() + fadeStart
        fadeOut.duration = 0.3
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        imgLayer.add(fadeOut, forKey: "failFade")
    }

    private static func latestDownloadsPNG() -> URL? {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"))
        guard let items = try? fm.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let pngs = items.filter { $0.pathExtension.lowercased() == "png" }
        return pngs.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    func startPulseOverlay(playSound: Bool = true) {
        if !pulseRunning { showPulse(playSound: playSound) }
    }

    func stopPulseOverlay() {
        if pulseRunning { _stopPulse() }
    }

    // MARK: - Pulse stop (called when button pressed while running)

    private func _stopPulse() {
        guard pulseRunning else { return }
        pulseRunning = false
        SoundManager.shared.stop("flatline.mp3")
        let dim = _pulseDimLayer
        let grid = _pulseGridLayer
        let ecg = _pulseEcgLayer
        _pulseDimLayer = nil
        _pulseGridLayer = nil
        _pulseEcgLayer = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            dim?.removeFromSuperlayer()
            grid?.removeFromSuperlayer()
            ecg?.removeFromSuperlayer()
        }
        for layer in [dim, grid, ecg].compactMap({ $0 }) {
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1; fadeOut.toValue = 0
            fadeOut.duration = 0.5
            fadeOut.fillMode = .forwards; fadeOut.isRemovedOnCompletion = false
            layer.add(fadeOut, forKey: "fadeOut")
        }
        CATransaction.commit()
    }

    // MARK: - Fire alarm GIF (bottom-left corner)

    func showFireAlarm(playSound: Bool = true) {
        if cancelIfRunning("fire-alarm", sound: playSound ? "school_bell.mp3" : nil) { return }

        guard let url = Bundle.module.url(forResource: "fire-alarm", withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            overlayError("fire-alarm.gif not found")
            return
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return }

        var images: [CGImage] = []
        var totalDuration: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(cg)
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gif  = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = gif?[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.05
            totalDuration += delay
        }

        let bounds = hostLayer.bounds
        // Size: ~31% of screen width (26% × 1.2 — grown 20% toward interior per user request)
        let size = bounds.width * 0.312
        // Bottom-left corner with small margin
        let margin: CGFloat = 20
        let x = margin
        let y = margin  // y=0 is bottom in flipped coordinates

        let gifLayer = CALayer()
        gifLayer.frame = CGRect(x: x, y: y, width: size, height: size)
        gifLayer.contentsGravity = .resizeAspect
        if let first = images.first { gifLayer.contents = first }
        hostLayer.addSublayer(gifLayer)

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = images
        anim.duration = totalDuration
        anim.repeatCount = .infinity  // loop until cancelled

        CATransaction.begin()
        gifLayer.add(anim, forKey: "fireAlarmFrames")
        CATransaction.commit()

        if playSound { SoundManager.shared.play("school_bell.mp3") }
        trackEffect("fire-alarm", layer: gifLayer, duration: 4.72, sound: playSound ? "school_bell.mp3" : nil)
    }

    // MARK: - Bullet holes (minigun)

    func showBulletHoles(playSound: Bool = true) {
        if cancelIfRunning("bullet-holes") { return }

        let bounds = hostLayer.bounds
        let totalDuration = 6.37
        let count = 60
        let spawnStart = 0.25
        let spawnEnd = totalDuration - 0.25

        guard let url = Bundle.module.url(forResource: "bullet_hole", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            overlayError("bullet_hole.png not found")
            return
        }

        if playSound { SoundManager.shared.play("minigun.mp3") }

        let container = CALayer()
        container.frame = bounds
        hostLayer.addSublayer(container)

        let interval = (spawnEnd - spawnStart) / Double(count - 1)
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        let holeW: CGFloat = image.size.width
        let holeH: CGFloat = image.size.height

        for i in 0..<count {
            let delay = spawnStart + Double(i) * interval
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak container] in
                guard let container = container else { return }
                let x = CGFloat.random(in: 0...(bounds.width - holeW))
                let y = CGFloat.random(in: 0...(bounds.height - holeH))
                let hole = CALayer()
                hole.frame = CGRect(x: x, y: y, width: holeW, height: holeH)
                hole.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                hole.contentsScale = scale
                hole.opacity = 0
                container.addSublayer(hole)
                // Pop in
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0.0; fadeIn.toValue = 1.0
                fadeIn.duration = 0.08
                fadeIn.fillMode = .forwards; fadeIn.isRemovedOnCompletion = false
                hole.add(fadeIn, forKey: "fadeIn")
            }
        }

        // Fade out entire container at the tail
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.beginTime = CACurrentMediaTime() + totalDuration - 0.4
        fadeOut.fromValue = 1.0; fadeOut.toValue = 0.0
        fadeOut.duration = 0.4
        fadeOut.fillMode = .forwards; fadeOut.isRemovedOnCompletion = false
        container.add(fadeOut, forKey: "fadeOut")

        trackEffect("bullet-holes", layer: container, duration: totalDuration + 0.1, sound: "minigun.mp3")
    }

    // MARK: - FBI Knock (screenshot zooms +10% x3, synced with door knocks)

    func showFbiKnock(playSound: Bool = true) {
        if cancelIfRunning("fbi-knock", sound: playSound ? "fbi.mp3" : nil) { return }

        let bounds = hostLayer.bounds
        let totalDuration = 3.3

        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first,
              let screenshot = CGDisplayCreateImage(
                  (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
              ) else { return }

        if playSound { SoundManager.shared.play("fbi.mp3") }

        let imgLayer = CALayer()
        imgLayer.frame = bounds
        imgLayer.contents = screenshot
        imgLayer.contentsGravity = .resizeAspectFill
        hostLayer.addSublayer(imgLayer)

        // Knock times detected from fbi.mp3: 0.406s, 0.615s, 0.813s — equal interval ~0.21s
        let knockTimes = [0.406, 0.615, 0.813]
        for knockTime in knockTimes {
            DispatchQueue.main.asyncAfter(deadline: .now() + knockTime) { [weak imgLayer] in
                guard let imgLayer = imgLayer else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.08)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                imgLayer.transform = CATransform3DMakeScale(1.07, 1.07, 1.0)
                CATransaction.commit()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + knockTime + 0.12) { [weak imgLayer] in
                guard let imgLayer = imgLayer else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.12)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
                imgLayer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.beginTime = CACurrentMediaTime() + totalDuration - 0.3
        fadeOut.fromValue = 1.0; fadeOut.toValue = 0.0
        fadeOut.duration = 0.3
        fadeOut.fillMode = .forwards; fadeOut.isRemovedOnCompletion = false
        imgLayer.add(fadeOut, forKey: "fadeOut")

        trackEffect("fbi-knock", layer: imgLayer, duration: totalDuration, sound: playSound ? "fbi.mp3" : nil)
    }

    // MARK: - Phone ring (screenshot shake)

    func showPhoneRing(playSound: Bool = true) {
        if cancelIfRunning("phone-ring", sound: playSound ? "red_phone.mp3" : nil) { return }

        let bounds = hostLayer.bounds
        let totalDuration = 2.29

        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first,
              let screenshot = CGDisplayCreateImage(
                  (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
              ) else { return }

        if playSound { SoundManager.shared.play("red_phone.mp3") }

        let imgLayer = CALayer()
        imgLayer.frame = bounds
        imgLayer.contents = screenshot
        imgLayer.contentsGravity = .resizeAspectFill
        hostLayer.addSublayer(imgLayer)

        // Shake: rapid random offsets ±20px horizontal, ±7px vertical
        let shake = CAKeyframeAnimation(keyPath: "position")
        shake.duration = totalDuration
        shake.calculationMode = .discrete
        let cx = bounds.midX, cy = bounds.midY
        var positions: [NSValue] = []
        let count = Int(totalDuration / 0.04) // ~25Hz
        for _ in 0..<count {
            let dx = CGFloat.random(in: -20...20)
            let dy = CGFloat.random(in: -7...7)
            positions.append(NSValue(point: CGPoint(x: cx + dx, y: cy + dy)))
        }
        positions.append(NSValue(point: CGPoint(x: cx, y: cy)))
        shake.values = positions
        imgLayer.add(shake, forKey: "shake")

        // Fade out over last 0.3s
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.beginTime = CACurrentMediaTime() + totalDuration - 0.3
        fadeOut.fromValue = 1.0; fadeOut.toValue = 0.0
        fadeOut.duration = 0.3
        fadeOut.fillMode = .forwards; fadeOut.isRemovedOnCompletion = false
        imgLayer.add(fadeOut, forKey: "fadeOut")

        trackEffect("phone-ring", layer: imgLayer, duration: totalDuration + 0.1, sound: playSound ? "red_phone.mp3" : nil)
    }

    // MARK: - Brother (looping GIF, bottom-left area, toggled by tablet sound)

    func showBrother(playSound: Bool = true) {
        if cancelIfRunning("brother", sound: playSound ? "sfx_109.mp3" : nil) { return }

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"))
        let gifURL = downloadsURL.appendingPathComponent("brother_full.gif")

        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            overlayError("brother_full.gif not found in Downloads")
            return
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return }

        var images: [CGImage] = []
        var totalDuration: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(cg)
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = gif?[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.05
            totalDuration += delay
        }

        let bounds = hostLayer.bounds
        let size = bounds.width * 0.32         // ~1/3 of screen width
        let x: CGFloat = 0                     // flush to left edge
        let y: CGFloat = -40                   // 40px below bottom

        let gifLayer = CALayer()
        gifLayer.frame = CGRect(x: x, y: y, width: size, height: size)
        gifLayer.contentsGravity = .resizeAspect
        if let first = images.first { gifLayer.contents = first }
        hostLayer.addSublayer(gifLayer)
        activeEffects["brother"] = gifLayer

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = images
        anim.duration = totalDuration
        anim.repeatCount = .infinity

        CATransaction.begin()
        gifLayer.add(anim, forKey: "brotherFrames")
        CATransaction.commit()

        if playSound {
            SoundManager.shared.play("sfx_109.mp3")
            if let soundURL = Bundle.module.url(forResource: "sfx_109", withExtension: "mp3") {
                let asset = AVURLAsset(url: soundURL)
                let d = asset.duration
                if d.isNumeric {
                    let soundDuration = CMTimeGetSeconds(d)
                    DispatchQueue.main.asyncAfter(deadline: .now() + soundDuration) { [weak self] in
                        self?.stopBrother()
                    }
                }
            }
        }
    }

    func stopBrother() {
        _ = cancelIfRunning("brother", sound: "sfx_109.mp3")
    }

    // MARK: - Gong GIF overlay (bottom-left, 25% screen width)

    func showGong(playSound: Bool = true) {
        if cancelIfRunning("gong", sound: playSound ? "gong.mp3" : nil) { return }
        guard let url = Bundle.module.url(forResource: "gong", withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return }

        var images: [CGImage] = []
        var totalDuration: Double = 0
        let skipFrames = 43  // skip static standing-still prefix
        for i in skipFrames..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            images.append(cg)
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = gif?[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.05
            totalDuration += delay
        }

        let bounds = hostLayer.bounds
        let w = bounds.width * 0.25
        let h = w * (600.0 / 800.0)           // preserve original 800x600 aspect ratio
        let x: CGFloat = 0
        let y: CGFloat = bounds.height - h

        let gifLayer = CALayer()
        gifLayer.frame = CGRect(x: x, y: y, width: w, height: h)
        gifLayer.contentsGravity = .resizeAspect
        if let first = images.first { gifLayer.contents = first }
        hostLayer.addSublayer(gifLayer)
        activeEffects["gong"] = gifLayer

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = images
        anim.duration = totalDuration
        anim.repeatCount = 1
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false

        CATransaction.begin()
        gifLayer.add(anim, forKey: "gongFrames")
        CATransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            _ = self?.cancelIfRunning("gong", sound: nil)
        }

        if playSound { SoundManager.shared.play("gong.mp3") }
    }

    // MARK: - Stop all active effects (called when tablet stops any sound)

    func stopAllActiveEffects() {
        for (_, layer) in activeEffects {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        activeEffects.removeAll()
        stopApplause()
        if pulseRunning { _stopPulse() }
        stopAlarmOverlay()
    }
}
