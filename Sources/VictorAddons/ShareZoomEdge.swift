import CoreGraphics
import Foundation

/// 🔎 How `ShareZoom` treats the edges of its slice: **one door per neighbouring monitor**
/// (Victor, 2026-11-04: *"dacă trec … prin centrul laturii … un edge roșu. Asta îmi arată
/// că pe acolo o să iasă"*).
///
/// Pushing an edge has to do two things: pan the picture, and reach the next monitor.
/// Until then a side with a monitor beyond it always let the pointer out, and panned
/// only after 300 ms of rest in the outer 10 % of the glass — so the pan along that side
/// was a wait, and a cursor resting just inside the edge (on its way out, or just back
/// in) dragged the picture away. Now the two have their own places:
///
/// - **The door lets the pointer out.** The middle 10 % of the stretch a side shares with
///   a monitor (`doors`), its stretch of the zigzag lined in red. A move across it lands on that monitor
///   at the spot where the drawn cursor touched the glass, and the picture stays put.
/// - **Everywhere else, pushing pans**, right away, on every side: the pointer runs on
///   past the slice's edge (`confine`) and the slice follows it (`ShareZoomPolicy.pan`).
/// - **Coming back never moves the picture**, wherever the pointer crosses: not only
///   through the door. It enters the slice where the hand crosses the glass edge
///   (`fromGlass`).
///
/// All rects are CG global (origin top-left, y down) unless said otherwise.
enum ShareZoomEdge {
    /// A side of the zoomed display, in CG terms (top = low y).
    enum Side: String { case left, right, top, bottom }

    /// The door's share of the stretch of side a monitor sits against.
    static let doorShare: CGFloat = 0.10

    /// Where the pointer may leave: a stretch of one side, as CG global y for left and
    /// right, x for top and bottom.
    struct Door: Equatable {
        let side: Side
        let span: ClosedRange<CGFloat>

        var isHorizontal: Bool { side == .top || side == .bottom }

        /// Whether a pointer crossing `crossing` at glass `g` goes through this door.
        func admits(_ crossing: Side, at g: CGPoint) -> Bool {
            side == crossing && span.contains(isHorizontal ? g.x : g.y)
        }

        /// The stretch of frame it occupies, where the red line shows: `depth` deep into
        /// the glass, in the display's own Cocoa coordinates (origin bottom-left, y up),
        /// which is what its layer uses.
        func strip(on display: CGRect, depth: CGFloat) -> CGRect {
            let length = span.upperBound - span.lowerBound
            switch side {
            case .right, .left:
                let x = side == .right ? display.width - depth : 0
                return CGRect(x: x, y: display.maxY - span.upperBound, width: depth, height: length)
            case .top, .bottom:
                let y = side == .top ? display.height - depth : 0
                return CGRect(x: span.lowerBound - display.minX, y: y, width: length, height: depth)
            }
        }
    }

    /// One door per monitor touching `display`, in the middle of the stretch they share.
    static func doors(display: CGRect, others: [CGRect]) -> [Door] {
        others.compactMap { o in
            let side: Side
            if o.minX == display.maxX { side = .right }
            else if o.maxX == display.minX { side = .left }
            else if o.minY == display.maxY { side = .bottom }
            else if o.maxY == display.minY { side = .top }
            else { return nil }
            let horizontal = side == .top || side == .bottom
            let from = horizontal ? max(o.minX, display.minX) : max(o.minY, display.minY)
            let to = horizontal ? min(o.maxX, display.maxX) : min(o.maxY, display.maxY)
            guard to > from else { return nil }
            let half = (to - from) * doorShare / 2
            let middle = (from + to) / 2
            return Door(side: side, span: (middle - half)...(middle + half))
        }
    }

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

    /// The point just past the zoomed display's `side` that a drawn cursor at glass `g`
    /// (CG global) crosses onto.
    static func probe(_ side: Side, glass g: CGPoint, display: CGRect) -> CGPoint {
        let gx = min(max(g.x, display.minX), display.maxX - 1)
        let gy = min(max(g.y, display.minY), display.maxY - 1)
        switch side {
        case .right: return CGPoint(x: display.maxX, y: gy)
        case .left: return CGPoint(x: display.minX - 1, y: gy)
        case .bottom: return CGPoint(x: gx, y: display.maxY)
        case .top: return CGPoint(x: gx, y: display.minY - 1)
        }
    }

    /// Where a (slowed) move to `next` ends: `next` itself inside the slice; across a
    /// slice edge through a door, on the monitor beyond it at the matching glass spot;
    /// otherwise `next`, kept on the zoomed display — past the slice's edge, so the slice
    /// follows it (`ShareZoomPolicy.pan`).
    static func confine(_ next: CGPoint, slice: CGRect, display: CGRect, doors: [Door]) -> CGPoint {
        let inside = clampInside(next, slice)
        if inside == next { return next }
        let g = toGlass(next, slice: slice, display: display)
        var sides: [Side] = []
        if next.x > inside.x { sides.append(.right) }
        if next.x < inside.x { sides.append(.left) }
        if next.y > inside.y { sides.append(.bottom) }
        if next.y < inside.y { sides.append(.top) }
        if let side = sides.first(where: { side in doors.contains { $0.admits(side, at: g) } }) {
            return probe(side, glass: g, display: display)
        }
        return CGPoint(x: min(max(next.x, display.minX), display.maxX - 1),
                       y: min(max(next.y, display.minY), display.maxY - 1))
    }

    static func clampInside(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        // A hair inside the far edges: `CGRect.contains` excludes maxX/maxY.
        CGPoint(x: min(max(p.x, r.minX), r.maxX - 0.01),
                y: min(max(p.y, r.minY), r.maxY - 0.01))
    }
}
