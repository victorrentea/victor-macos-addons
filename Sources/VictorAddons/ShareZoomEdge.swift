import CoreGraphics
import Foundation

/// 🔎 How `ShareZoom` treats the edges of its slice (Victor, 2026-11-02: *"dacă mut
/// mouse-ul repede peste edge, să nu facă pan. Dacă-l las în zona magnificată adiacentă
/// marginii (undeva pe 10 % din suprafață), panul să înceapă după 300 ms"*).
///
/// Until then the slice followed the pointer the moment it pushed an edge
/// (`ShareZoomPolicy.pan`, macOS's "only when the pointer reaches an edge"), so a quick
/// trip to the next monitor — to fetch an animation, say — dragged the whole picture to
/// that side of the desktop on the way out. Now:
///
/// - **The edge of the slice is the edge of the screen.** A move that would leave the
///   slice lands on the adjacent display, at the spot where the drawn cursor touched the
///   glass, and the picture stays put. With no display on that side the pointer stops
///   at the edge (`confine`). Coming back, the pointer enters the slice where the hand
///   crosses the glass edge (`fromGlass`).
/// - **Dwelling pans.** The drawn cursor inside the outer `band` of the glass for
///   `dwell` seconds pans that way, faster the deeper in the band (`speed`), and the
///   pointer travels with the picture so it stays at the same spot on the glass.
///
/// All rects are CG global (origin top-left, y down) unless said otherwise.
enum ShareZoomEdge {
    /// The outer share of the glass, per side, that pans when the cursor rests in it.
    static let band: CGFloat = 0.10
    /// How long the cursor must rest in the band before the picture moves.
    static let dwell: CFTimeInterval = 0.3
    /// Pan speed in glass widths (or heights) per second: at the band's inner border,
    /// and against the edge itself.
    static let innerSpeed: CGFloat = 0.3
    static let outerSpeed: CGFloat = 1.2

    /// Where desktop point `p` (inside `slice`) is drawn on the screen.
    static func toGlass(_ p: CGPoint, slice: CGRect, display: CGRect) -> CGPoint {
        let k = display.width / max(slice.width, 1)
        return CGPoint(x: display.minX + (p.x - slice.minX) * k,
                       y: display.minY + (p.y - slice.minY) * k)
    }

    /// The desktop point drawn at screen point `g`.
    static func fromGlass(_ g: CGPoint, slice: CGRect, display: CGRect) -> CGPoint {
        let k = display.width / max(slice.width, 1)
        let p = CGPoint(x: slice.minX + (g.x - display.minX) / k,
                        y: slice.minY + (g.y - display.minY) / k)
        return clampInside(p, slice)
    }

    /// Where a (slowed) move to `next` ends: `next` itself inside the slice; across a
    /// slice edge, on the display beyond the zoomed one at the matching glass spot, if
    /// `hasDisplay` finds one there; otherwise held at the edge.
    static func confine(_ next: CGPoint, slice: CGRect, display: CGRect,
                        hasDisplay: (CGPoint) -> Bool) -> CGPoint {
        let inside = clampInside(next, slice)
        if inside == next { return next }
        let g = toGlass(next, slice: slice, display: display)
        let gx = min(max(g.x, display.minX), display.maxX - 1)
        let gy = min(max(g.y, display.minY), display.maxY - 1)
        var probes: [CGPoint] = []
        if next.x > inside.x { probes.append(CGPoint(x: display.maxX, y: gy)) }
        if next.x < inside.x { probes.append(CGPoint(x: display.minX - 1, y: gy)) }
        if next.y > inside.y { probes.append(CGPoint(x: gx, y: display.maxY)) }
        if next.y < inside.y { probes.append(CGPoint(x: gx, y: display.minY - 1)) }
        return probes.first(where: hasDisplay) ?? inside
    }

    static func clampInside(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        // A hair inside the far edges: `CGRect.contains` excludes maxX/maxY.
        CGPoint(x: min(max(p.x, r.minX), r.maxX - 0.01),
                y: min(max(p.y, r.minY), r.maxY - 0.01))
    }

    /// How deep the drawn cursor sits in the band along one axis: nil outside it, else
    /// a signed depth, −1…0 at the low edge, 0…1 at the high one (0 = band border,
    /// ±1 = against the screen edge). `g` and `length` are along that axis, display-local.
    static func depth(_ g: CGFloat, length: CGFloat) -> CGFloat? {
        let b = length * band
        guard b > 0 else { return nil }
        if g >= length - b { return min((g - (length - b)) / b, 1) }
        if g <= b { return -min((b - g) / b, 1) }
        return nil
    }

    /// The pan, in desktop units, for `dt` seconds at signed `depth`, on an axis whose
    /// glass is `length` long at factor `k`.
    static func step(depth: CGFloat, length: CGFloat, factor k: CGFloat, dt: CGFloat) -> CGFloat {
        let v = innerSpeed + (outerSpeed - innerSpeed) * abs(depth)
        let s: CGFloat = depth < 0 ? -1 : 1
        return s * v * length / max(k, 1) * dt
    }

    /// Per axis, when the cursor entered the band and on which side. Main thread.
    struct Dwell {
        var side: Int = 0
        var since: CFTimeInterval = 0

        /// Updates with the current `depth` and answers whether the pan is due.
        mutating func due(depth: CGFloat?, now: CFTimeInterval) -> Bool {
            guard let d = depth else { side = 0; return false }
            let s = d < 0 ? -1 : 1
            if s != side { side = s; since = now }
            return now - since >= dwell
        }
    }
}
