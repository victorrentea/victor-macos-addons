import Foundation

/// The pure geometry behind ⌘⌃A tiling: given the frames of the Terminal windows
/// living on one display, decide where each of them goes.
///
/// It is a separate, dependency-free enum (no AppKit, no Accessibility) precisely
/// so the decisions below can be unit-tested — the same split as
/// `TerminalZoomSizeLockPolicy` and `TerminalZoomTargetPolicy`.
///
/// **Nothing ever overlaps.** Four windows fill the quadrants; the fifth and up
/// *split a quadrant in two* rather than being piled on top of one. The first cut
/// of this (2026-09-08) fanned the extras diagonally over the bottom-right tile,
/// each stepped 32 pt down-right so a strip of every title bar stayed exposed —
/// and a strip is not the same thing as a window. 2026-09-09: *"never never
/// overlap tiles like this one over the other — create separate tiles per
/// quadrant"*. A title bar you can only see a corner of tells you a window exists;
/// a title bar you can see whole tells you **which** session it is and blinks its
/// Claude glyph when that session has something to say, which is the actual reason
/// for pressing ⌘⌃A.
///
/// **The quadrants take the extras in a fixed order: bottom-right, bottom-left,
/// top-right, top-left** (`fillOrder`). So the fifth window halves the
/// bottom-right quadrant, the sixth halves the bottom-left, the seventh the
/// top-right, the eighth the top-left, and the ninth goes back to the bottom-right
/// for a third slice. The order starts at the bottom because that is where the
/// hands and the eyes already are — the top of the screen is the half you glance
/// at, the bottom the half you work in.
///
/// **A quadrant splits into rows, never columns.** Halving the width would halve
/// the *title*, and the title is what all of this is protecting; halving the height
/// costs lines of scrollback, which is the cheaper thing to lose.
///
/// **A window keeps the slot it is already in.** Which window goes where is decided
/// by *where it currently sits*, never by z-order: pressing ⌘⌃A twice must be a
/// no-op. It used to hand the four quadrants to the four front-most windows, so the
/// windows that had just been raised swapped places with the tiles on every press
/// (2026-09-08: *"le cam face shuffle"*). Matching is greedy nearest-pair on window
/// **origin and size**, not centre: the two halves of a split quadrant have
/// centres of their own, but a whole quadrant and its top half share an origin, so
/// the size term is what tells them apart. A window already on its target matches
/// at cost 0 and wins it before anything else can, which is what makes re-tiling
/// idempotent.
enum TerminalTileLayout {

    struct Rect: Hashable {
        let x: Int, y: Int, w: Int, h: Int
        var x2: Int { x + w }
        var y2: Int { y + h }
        var center: (Double, Double) { (Double(x) + Double(w) / 2, Double(y) + Double(h) / 2) }
    }

    /// Gap left between quadrants (and against the top of the screen).
    static let margin = 2

    /// Which quadrant takes the next window once all four are occupied:
    /// bottom-right first, then bottom-left, top-right, top-left. Indices into
    /// `quadrants(of:)`.
    static let fillOrder = [3, 2, 1, 0]

    // MARK: - Quadrants

    static func quadrants(of d: Rect) -> [Rect] {
        let hw = d.w / 2, hh = d.h / 2
        return [
            Rect(x: d.x + margin, y: d.y + margin, w: hw - margin, h: hh - margin),
            Rect(x: d.x + hw,     y: d.y + margin, w: hw - margin, h: hh - margin),
            Rect(x: d.x + margin, y: d.y + hh,     w: hw - margin, h: hh - margin),
            Rect(x: d.x + hw,     y: d.y + hh,     w: hw - margin, h: hh - margin),
        ]
    }

    // MARK: - Layout

    /// How many windows each quadrant holds, in quadrant order, for `count`
    /// windows on the display. Everyone gets one, then the extras are dealt out
    /// round-robin in `fillOrder` — so the bottom-right quadrant is always the
    /// most crowded and the top-left the least.
    static func capacities(count: Int) -> [Int] {
        var caps = [Int](repeating: 1, count: 4)
        guard count > 4 else { return caps }
        for i in 0..<(count - 4) { caps[fillOrder[i % 4]] += 1 }
        return caps
    }

    /// `count` full-width rows stacked down `quad`, abutting exactly the way the
    /// quadrants themselves abut — no overlap, no gap, no pixel of the quadrant
    /// left over. Integer division is done on the *edges* rather than on the
    /// height so the rounding error cannot accumulate into a seam.
    static func rows(count: Int, in quad: Rect) -> [Rect] {
        guard count > 1 else { return count == 1 ? [quad] : [] }
        return (0..<count).map { i in
            let top = quad.y + quad.h * i / count
            let bottom = quad.y + quad.h * (i + 1) / count
            return Rect(x: quad.x, y: top, w: quad.w, h: bottom - top)
        }
    }

    /// Every slot on the display, in **layout order**: the four quadrants
    /// (top-left, top-right, bottom-left, bottom-right), each one already split
    /// into as many rows as it has to hold. Exactly `count` slots come back once
    /// there are more windows than quadrants, and they tile the screen without
    /// overlapping.
    static func targets(count: Int, display: Rect) -> [Rect] {
        let quads = quadrants(of: display)
        guard count > quads.count else { return quads }
        let caps = capacities(count: count)
        return quads.enumerated().flatMap { rows(count: caps[$0.offset], in: $0.element) }
    }

    /// Which slot each window goes to, as an index into `targets(count:display:)`
    /// — in the same order as `windows`.
    static func assign(windows: [Rect], display: Rect) -> [Int] {
        assign(windows: windows, targets: targets(count: windows.count, display: display))
    }

    /// Target frame for every window, in the order given.
    static func frames(windows: [Rect], display: Rect) -> [Rect] {
        guard !windows.isEmpty else { return [] }
        let slots = targets(count: windows.count, display: display)
        return assign(windows: windows, targets: slots).map { slots[$0] }
    }

    /// Greedy nearest-pair matching: repeatedly take the closest window/slot pair
    /// still unclaimed. Not provably the cheapest total, but **stable**, which is
    /// worth more here — a window already sitting on a slot is at distance 0 and
    /// takes it before any other pair is even considered, so a layout that is
    /// already tiled reproduces itself exactly. Ties break on window order, so the
    /// result never depends on dictionary or timing luck.
    static func assign(windows: [Rect], targets: [Rect]) -> [Int] {
        var pairs: [(cost: Int, w: Int, t: Int)] = []
        pairs.reserveCapacity(windows.count * targets.count)
        for (i, w) in windows.enumerated() {
            for (j, t) in targets.enumerated() { pairs.append((cost(w, t), i, j)) }
        }
        pairs.sort {
            if $0.cost != $1.cost { return $0.cost < $1.cost }
            if $0.w != $1.w { return $0.w < $1.w }
            return $0.t < $1.t
        }

        var out = [Int](repeating: -1, count: windows.count)
        var takenSlot = [Bool](repeating: false, count: targets.count)
        var placed = 0
        for p in pairs where out[p.w] == -1 && !takenSlot[p.t] {
            out[p.w] = p.t
            takenSlot[p.t] = true
            placed += 1
            if placed == windows.count { break }
        }
        return out
    }

    /// How far a window is from a slot: corner distance, plus half the size
    /// mismatch. Corners separate the rows of a split quadrant from each other;
    /// the size term is what separates a whole quadrant from its own top row,
    /// which share a corner exactly.
    private static func cost(_ a: Rect, _ b: Rect) -> Int {
        abs(a.x - b.x) + abs(a.y - b.y) + (abs(a.w - b.w) + abs(a.h - b.h)) / 2
    }

}
