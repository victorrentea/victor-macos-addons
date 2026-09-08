import Foundation

/// The pure geometry behind ⌘⌃A tiling: given the frames of the Terminal windows
/// living on one display, decide where each of them goes.
///
/// It is a separate, dependency-free enum (no AppKit, no Accessibility) precisely
/// so the decisions below can be unit-tested — the same split as
/// `TerminalZoomSizeLockPolicy` and `TerminalZoomTargetPolicy`.
///
/// **Four windows fill the quadrants; the fifth and up fan out.** A screen has
/// four readable quarters and no more, so the extras used to be left wherever they
/// happened to sit — behind the tiled ones, uncountable. They are now stacked over
/// the **bottom-right** quadrant with a diagonal offset, which keeps a strip of
/// every window's title bar exposed: you can see how many there are and drag any
/// one of them out by the part that shows.
///
/// **The fan only reads if it opens downwards** — offset *and* depth have to agree.
/// A window's title bar sits at its top, so the window stepped further down-right
/// must be the one in **front**: then each window behind it shows a full title bar
/// above. Get that backwards and the pile is technically fanned and practically
/// invisible — the front window covers every title bar behind it except a
/// `cascadeStep`-wide sliver at the far right, which is what the first cut of this
/// did (2026-09-08: *"restul sunt una sub alta"*). So `TerminalTiler` raises the
/// windows in **slot order** — top-left, top-right, bottom-left, bottom-right, then
/// the fan from the shallowest slot to the deepest — and every title bar on the
/// screen ends up visible.
///
/// **A window keeps the slot it is already in.** Which window goes where is decided
/// by *where it currently sits*, never by z-order: pressing ⌘⌃A twice must be a
/// no-op. It used to hand the four quadrants to the four front-most windows, so the
/// fan — which the raise had just brought to the front — swapped places with the
/// tiles on every press (2026-09-08: *"le cam face shuffle"*). Matching is greedy
/// nearest-pair on window **origin and size**, not centre: a fan slot and the
/// quadrant it lies in share a centre almost exactly, so centres cannot tell "the
/// bottom-right tile" from "the window fanned on top of it", while origins differ by
/// a whole `cascadeStep`. A window already on its target matches at cost 0 and wins
/// it before anything else can, which is what makes re-tiling idempotent.
enum TerminalTileLayout {

    struct Rect: Hashable {
        let x: Int, y: Int, w: Int, h: Int
        var x2: Int { x + w }
        var y2: Int { y + h }
        var center: (Double, Double) { (Double(x) + Double(w) / 2, Double(y) + Double(h) / 2) }
    }

    /// Gap left between quadrants (and against the top of the screen).
    static let margin = 2

    /// The quadrant the cascade piles onto — bottom-right.
    static let cascadeQuadrant = 3

    /// Diagonal offset between two cascaded windows, when there is room for it.
    /// A Terminal title bar is ~28 pt tall, so 32 exposes a whole one.
    static let cascadeStep = 32

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

    /// Every slot on the display, in **layout order**: the four quadrants
    /// (top-left, top-right, bottom-left, bottom-right) and then, once there are
    /// more windows than quadrants, one fan slot per extra — shallowest first.
    ///
    /// That order is also the order the windows are raised in, which is why it is
    /// the order the array is in: raising them shallowest-to-deepest leaves every
    /// title bar showing.
    static func targets(count: Int, display: Rect) -> [Rect] {
        let quads = quadrants(of: display)
        guard count > quads.count else { return quads }
        return quads + cascade(count: count - quads.count, over: quads[cascadeQuadrant])
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
    /// mismatch. Corners are what distinguish the slots of a fan from each other
    /// and from the quadrant they lie on; the size term is the tie-breaker for two
    /// windows sharing a corner.
    private static func cost(_ a: Rect, _ b: Rect) -> Int {
        abs(a.x - b.x) + abs(a.y - b.y) + (abs(a.w - b.w) + abs(a.h - b.h)) / 2
    }

    /// `count` frames stepping down-right across `base`, in slot order (nearest the
    /// corner first). The **first step is taken immediately**, so slot 0 already
    /// clears `base` by one `cascadeStep`: the window tiled into that quadrant is
    /// the back of the fan and keeps its own title bar showing above the pile —
    /// the extras sit *on top of* the bottom-right window, they do not replace it.
    /// The last slot lands flush with the quadrant's bottom-right corner, so the
    /// whole fan stays inside it (and therefore on screen) and never covers one of
    /// the other three tiles. Many windows tighten the step rather than letting the
    /// windows shrink without bound.
    static func cascade(count: Int, over base: Rect) -> [Rect] {
        guard count > 0 else { return [] }

        let maxSpread = max(0, min(base.w, base.h) / 2)
        let step = max(8, min(cascadeStep, maxSpread / count))
        let spread = step * count
        let w = max(200, base.w - spread)
        let h = max(120, base.h - spread)

        return (1...count).map { i in
            Rect(x: base.x + i * step, y: base.y + i * step, w: w, h: h)
        }
    }

}
