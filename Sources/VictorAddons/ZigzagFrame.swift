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
    /// The way out is the way in played backwards (Victor, 2026-11-02: *"simetrică
    /// invers"*): same durations, and ease-in is ease-out reversed in time.
    static let fadeIn: CFTimeInterval = 0.12
    static let sharpen: CFTimeInterval = 0.3
    static let flatten: CFTimeInterval = sharpen
    static let fadeOut: CFTimeInterval = fadeIn

    /// The black: the screen's rectangle minus the ring, even-odd.
    static func fill(_ bounds: CGRect, sharpness: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRect(bounds)
        p.addPath(ShareZoom.zigzagRing(size: bounds.size, sharpness: sharpness))
        return p
    }

    /// The frame's inner outline, which `line` (a sublayer riding it) strokes.
    static func ring(_ bounds: CGRect, sharpness: CGFloat) -> CGPath {
        ShareZoom.zigzagRing(size: bounds.size, sharpness: sharpness)
    }

    /// Sets the frame sharp or flat, visible or not, with no animation left on it.
    static func set(edge: CAShapeLayer, line: CAShapeLayer? = nil, sharp: Bool, visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.removeAllAnimations()
        edge.opacity = visible ? 1 : 0
        edge.path = fill(edge.bounds, sharpness: sharp ? 1 : 0)
        line?.removeAllAnimations()
        line?.path = ring(edge.bounds, sharpness: sharp ? 1 : 0)
        CATransaction.commit()
    }

    /// Fade in flat, then sharpen, starting `delay` from now (nothing shows before).
    /// Answers how long it takes, delay included.
    @discardableResult
    static func appear(edge: CAShapeLayer, line: CAShapeLayer? = nil,
                       after delay: CFTimeInterval = 0) -> CFTimeInterval {
        // One transaction for the end state and the animations: committed apart, the
        // end state reached the screen a frame early — the frame blinked (2026-11-02).
        CATransaction.begin()
        defer { CATransaction.commit() }
        set(edge: edge, line: line, sharp: true, visible: true)
        let now = CACurrentMediaTime() + delay
        let flat = fill(edge.bounds, sharpness: 0), sharp = fill(edge.bounds, sharpness: 1)
        edge.add(anim("opacity", 0, 1, at: now, for: fadeIn, ease: .easeOut, holdBefore: true), forKey: "fade")
        edge.add(anim("path", flat, sharp, at: now + fadeIn, for: sharpen, ease: .easeOut, holdBefore: true),
                 forKey: "sharpness")
        line?.add(anim("path", ring(edge.bounds, sharpness: 0), ring(edge.bounds, sharpness: 1),
                       at: now + fadeIn, for: sharpen, ease: .easeOut, holdBefore: true), forKey: "sharpness")
        return delay + fadeIn + sharpen
    }

    /// Flatten, then fade out, starting `delay` from now (sharp until then). Answers
    /// how long it takes, delay included.
    @discardableResult
    static func disappear(edge: CAShapeLayer, line: CAShapeLayer? = nil,
                          after delay: CFTimeInterval = 0) -> CFTimeInterval {
        CATransaction.begin()
        defer { CATransaction.commit() }
        set(edge: edge, line: line, sharp: false, visible: false)
        let now = CACurrentMediaTime() + delay
        let flat = fill(edge.bounds, sharpness: 0), sharp = fill(edge.bounds, sharpness: 1)
        edge.add(anim("path", sharp, flat, at: now, for: flatten, ease: .easeIn, holdBefore: true),
                 forKey: "sharpness")
        line?.add(anim("path", ring(edge.bounds, sharpness: 1), ring(edge.bounds, sharpness: 0),
                       at: now, for: flatten, ease: .easeIn, holdBefore: true), forKey: "sharpness")
        edge.add(anim("opacity", 1, 0, at: now + flatten, for: fadeOut, ease: .easeIn, holdBefore: true),
                 forKey: "fade")
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
