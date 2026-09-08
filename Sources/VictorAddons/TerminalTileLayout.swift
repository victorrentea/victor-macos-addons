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
/// did (2026-09-08: *"restul sunt una sub alta"*). Hence the front-most window gets
/// the **deepest** slot (`frames` reverses the slots) and `TerminalTiler` raises the
/// pile in the matching order.
enum TerminalTileLayout {

    struct Rect: Equatable {
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

    /// Target frame for every window, in the order given — which is
    /// **front-to-back**, the order the Accessibility API hands windows over in.
    /// The first four take the quadrants (each the nearest free one, so nothing
    /// travels further than it must); the rest cascade.
    static func frames(windows: [Rect], display: Rect) -> [Rect] {
        guard !windows.isEmpty else { return [] }
        let quads = quadrants(of: display)
        let tiled = Array(windows.prefix(quads.count))
        let extras = windows.count - tiled.count

        // The front-most window is the one being typed in — the terminal ⌘⌃C just
        // opened, most of the time — so it is kept out of the quadrant the pile
        // lands on. Otherwise opening a terminal while the mouse sits in the
        // bottom-right quarter would bury that brand-new window under the cascade.
        let forbidden = extras > 0 ? cascadeQuadrant : nil
        let assignment = assignOptimally(windowRects: tiled, quads: quads, forbiddenForFirst: forbidden)

        var out = assignment.map { quads[$0] }
        // Reversed: the front-most extra takes the deepest slot, so the window in
        // front is the lowest one and every title bar behind it stays visible.
        out.append(contentsOf: cascade(count: extras, over: quads[cascadeQuadrant]).reversed())
        return out
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

    // MARK: - Assignment

    private static func dist2(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = a.0 - b.0, dy = a.1 - b.1
        return dx * dx + dy * dy
    }

    private static func permutations(of n: Int, choose k: Int) -> [[Int]] {
        if k == 0 { return [[]] }
        var result: [[Int]] = []
        for i in 0..<n {
            for rest in permutations(of: n, choose: k - 1) where !rest.contains(i) {
                result.append([i] + rest)
            }
        }
        return result
    }

    /// Brute-force the assignment that moves the windows the least in total
    /// (≤4 windows per display, so 24 permutations at worst).
    static func assignOptimally(windowRects: [Rect], quads: [Rect],
                                forbiddenForFirst: Int? = nil) -> [Int] {
        var bestPerm: [Int] = []
        var bestCost = Double.infinity
        for perm in permutations(of: quads.count, choose: windowRects.count) {
            if let forbidden = forbiddenForFirst, perm.first == forbidden { continue }
            let cost = (0..<windowRects.count).reduce(0.0) { acc, i in
                acc + dist2(windowRects[i].center, quads[perm[i]].center)
            }
            if cost < bestCost { bestCost = cost; bestPerm = perm }
        }
        return bestPerm
    }
}
