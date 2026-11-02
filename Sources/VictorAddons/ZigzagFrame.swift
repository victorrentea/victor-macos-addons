import AppKit
import QuartzCore

/// 🔎 How ShareZoom's black zigzag frame comes and goes (Victor, 2026-11-02): never a
/// pop and never a plain cross-fade, but **in two beats**. Arriving, a flat black band
/// fades in along the screen's edge, then its teeth grow out of it (*"adâncirea
/// marginilor"*). Leaving, the teeth sink back into the band until it is straight
/// (*"se aplatizează"*), then the band fades out. Used by the zoom itself (first
/// ⌥+scroll in, back to 1× out) and by the ⌥ + wheel click engine flip
/// (`ZoomSwitchEffect`), so the frame always says the same thing the same way:
/// sharpening = our zoom, flattening = not any more.
enum ZigzagFrame {
    static let fadeIn: CFTimeInterval = 0.12
    static let sharpen: CFTimeInterval = 0.3
    static let flatten: CFTimeInterval = 0.35
    static let fadeOut: CFTimeInterval = 0.15

    /// The black: the screen's rectangle minus the ring, even-odd.
    static func fill(_ bounds: CGRect, sharpness: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRect(bounds)
        p.addPath(ShareZoom.zigzagRing(size: bounds.size, sharpness: sharpness))
        return p
    }

    static func line(_ bounds: CGRect, sharpness: CGFloat) -> CGPath {
        ShareZoom.zigzagRing(size: bounds.size, sharpness: sharpness)
    }

    /// Sets both layers sharp or flat, visible or not, with no animation left on them.
    static func set(edge: CAShapeLayer, line: CAShapeLayer, sharp: Bool, visible: Bool) {
        let b = edge.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [edge, line] { l.removeAllAnimations(); l.opacity = visible ? 1 : 0 }
        edge.path = fill(b, sharpness: sharp ? 1 : 0)
        line.path = Self.line(b, sharpness: sharp ? 1 : 0)
        CATransaction.commit()
    }

    /// Fade in flat, then sharpen. Answers how long it takes.
    @discardableResult
    static func appear(edge: CAShapeLayer, line: CAShapeLayer) -> CFTimeInterval {
        set(edge: edge, line: line, sharp: true, visible: true)
        let now = CACurrentMediaTime()
        for (layer, flat, sharp) in [(edge, fill(edge.bounds, sharpness: 0), fill(edge.bounds, sharpness: 1)),
                                     (line, Self.line(line.bounds, sharpness: 0), Self.line(line.bounds, sharpness: 1))] {
            layer.add(anim("opacity", 0, 1, at: now, for: fadeIn, ease: .easeOut), forKey: "fade")
            layer.add(anim("path", flat, sharp, at: now + fadeIn, for: sharpen, ease: .easeOut, holdBefore: true),
                      forKey: "sharpness")
        }
        return fadeIn + sharpen
    }

    /// Flatten, then fade out. Answers how long it takes.
    @discardableResult
    static func disappear(edge: CAShapeLayer, line: CAShapeLayer, after delay: CFTimeInterval = 0) -> CFTimeInterval {
        let now = CACurrentMediaTime() + delay
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [edge, line] { l.opacity = 0 }
        edge.path = fill(edge.bounds, sharpness: 0)
        line.path = Self.line(line.bounds, sharpness: 0)
        CATransaction.commit()
        for (layer, sharp, flat) in [(edge, fill(edge.bounds, sharpness: 1), fill(edge.bounds, sharpness: 0)),
                                     (line, Self.line(line.bounds, sharpness: 1), Self.line(line.bounds, sharpness: 0))] {
            layer.add(anim("path", sharp, flat, at: now, for: flatten, ease: .easeIn, holdBefore: true),
                      forKey: "sharpness")
            layer.add(anim("opacity", 1, 0, at: now + flatten, for: fadeOut, ease: .easeIn, holdBefore: true),
                      forKey: "fade")
        }
        return delay + flatten + fadeOut
    }

    private static func anim(_ key: String, _ from: Any, _ to: Any, at begin: CFTimeInterval,
                             for duration: CFTimeInterval, ease: CAMediaTimingFunctionName,
                             holdBefore: Bool = false) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.beginTime = begin
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: ease)
        // Before it starts, a delayed animation shows its `from`, not the model value.
        if holdBefore { a.fillMode = .backwards }
        return a
    }
}
