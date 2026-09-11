import Foundation

/// The pure geometry behind ⌘⌃A tiling: given the frames of the Terminal windows
/// living on one display, decide where each of them goes.
///
/// It is a separate, dependency-free enum (no AppKit, no Accessibility) precisely
/// so the decisions below can be unit-tested — the same split as
/// `TerminalZoomSizeLockPolicy` and `TerminalZoomTargetPolicy`.
///
/// **Four windows fill the quadrants; the fifth and up cascade inside one.** A
/// quadrant holds a Windows-style pile: the deepest window *is* the whole
/// quadrant, and every window in front of it is a little smaller, pinned to the
/// quadrant's **bottom-right corner**, so it never leaves the quarter it belongs
/// to. What the shrinking exposes is an L of the window behind: `titleStep` (32 pt)
/// of height, which is a whole Terminal title bar, and `sideStep` (21 pt) of width
/// down the left, which is enough to see the Claude activity bubble spinning in a
/// session you are not looking at. Those two numbers are the entire design — the
/// pile is read along its top-left staircase, and a step has to be tall enough to
/// name the session and wide enough to show whether it is working. The horizontal
/// one started at twice the vertical and was cut to a third of that (2026-09-09):
/// a spinner needs a couple of characters, not a column, and every point spent on
/// the staircase is a point the terminals in the pile do not get.
///
/// The first cut of this (2026-09-08) stepped the extras down-right *without*
/// pinning them, so the pile walked out of its quadrant and shrank on both edges
/// at once. The second (2026-09-09) banned overlap altogether and cut a quadrant
/// into rows, which is worse still: four terminals sliced into rows are four
/// terminals you cannot use. 2026-09-09, after seeing both: *"like in Windows,
/// tiling of windows in a cascade style from larger to smaller, always bound"*.
///
/// **A pile is seven windows deep and no more** (`maxDepth`, 2026-09-09: *"max 7
/// terminals / quadrant"*) — past that the staircase is longer than a glance takes
/// in, and each step eats screen the terminal underneath needs. A window also
/// never shrinks past half the quadrant on either axis (a quarter of its area,
/// `minFraction`), which is the floor on small screens where six nominal steps
/// would not fit; `depth(in:)` is whichever of the two limits bites first.
///
/// **The quadrants fill in a fixed order: bottom-right, bottom-left, top-right,
/// top-left** (`fillOrder`), each one **to its capacity** before the next is
/// touched. The order starts at the bottom because that is where the hands and the
/// eyes already are — the top of the screen is the half you glance at, the bottom
/// the half you work in. Past four full quadrants the extras are dealt round-robin
/// and the steps tighten rather than the windows shrinking without bound.
///
/// **Depth order is slot order.** Each quadrant's cascade comes back deepest
/// first, and `TerminalTiler` raises the windows in exactly that order, so every
/// window ends up in front of the bigger one behind it and every title bar on the
/// screen stays readable. Get that backwards and the pile is technically cascaded
/// and practically invisible (2026-09-08: *"restul sunt una sub alta"*).
///
/// **A window keeps the quadrant it is already in.** Which window goes where is
/// decided by *where it currently sits*: pressing ⌘⌃A twice must be a
/// no-op. It used to hand the four quadrants to the four front-most windows, so the
/// windows that had just been raised swapped places with the tiles on every press
/// (2026-09-08: *"le cam face shuffle"*). Matching is greedy nearest-pair on window
/// **origin and size**, not centre: two windows of the same pile share a centre
/// almost exactly, while their origins differ by a whole step. A window already on
/// its target matches at cost 0 and wins it before anything else can, which is what
/// makes re-tiling idempotent.
///
/// **…except the window that has the keyboard, which gets the best slot on the
/// screen.** `topSlots` is the front-most slot of every quadrant — the ones nothing
/// is stacked on top of — narrowed to those of the largest area, and the focused
/// window is pinned to whichever of them it is nearest before anything else is
/// matched (2026-09-09: *"the terminal … focused at the beginning of the tile … in
/// the position that has the largest surface and is also on top of the others"*).
/// With four windows or fewer every quadrant is that size, so the nearest one is
/// the one the window is already in and nothing moves; once a pile exists, the
/// quadrants still holding a single window are strictly bigger than any cascaded
/// slot, so the keyboard is lifted out of the pile onto a whole quadrant — usually
/// the top-left, the last one `fillOrder` gets round to. This is also what settles
/// the old collision between "the keyboard stays put" and "the pile stays
/// readable": the focused window is raised last by `TerminalTiler`, and now it sits
/// where being on top covers nothing.
/// **Inside a pile, depth is z-order — because ⌘` is z-order.** Which quadrant a
/// window lands in is geometry, but *how deep in the pile* it sits is dealt from
/// the front-to-back order the windows already had (`dealPilesByDepth`): the
/// back-most window of a quadrant becomes the whole quadrant, the front-most the
/// smallest step. That is the only way to have both halves of what a pile is: the
/// smaller window has to be in front of the bigger one to be seen at all, and
/// `TerminalTiler` no longer buys that by re-stacking the windows — it puts the
/// z-order back exactly as it found it, so ⌘` and ⌘⇧` still walk the terminals in
/// the same sequence after a tile as before it (2026-09-10: *"la cmd ` sau cmd
/// shift ` să am aceeaşi ordine … să pot merge înapoi pe terminalul precedent"*).
/// Depth and z-order being the same thing, one of the two has to give: dealing the
/// slots by z is what lets the stacking stay untouched. Re-tiling is still a no-op
/// — after a tile the pile's depth already *is* its z-order, so the same deal comes
/// out again — and the window holding the keyboard keeps the slot the pin gave it,
/// the rest of its pile being dealt around it.
///
/// **The terminals running a Claude session get first refusal on the quadrants
/// nobody is stacked on** (2026-09-11: *"să pui vizibile … terminalele în care
/// găsești [Claude] instances în rulare"*). After the keyboard has taken its slot,
/// the windows `ClaudeSessionTitle` recognises are matched — nearest-pair again,
/// so an already-tiled screen re-tiles to itself — against `wholeQuadrantSlots`,
/// and only then is everyone else dealt into what is left. With a dozen sessions
/// and two spare shells open, which is the ordinary state of this Mac, it is the
/// two shells that go to the bottom of a pile.
///
/// It is deliberately *only* the whole quadrants that are handed out this way, not
/// every unobstructed slot. The front slot of a pile is unobstructed on the
/// **screen**, but only for the window that is also in front in **z** — and z is
/// what the tile is forbidden to touch — so giving it to a back-most window would
/// bury it completely, which is the opposite of the request. A quadrant holding a
/// single window has nobody to be buried by, whatever the stacking order says, and
/// that is what makes this rule and the ⌘` rule able to hold at the same time. A
/// session that does not fit in one is dealt into a pile like any other window:
/// *"atât cât poți"*.
///
enum TerminalTileLayout {

    struct Rect: Hashable {
        let x: Int, y: Int, w: Int, h: Int
        var x2: Int { x + w }
        var y2: Int { y + h }
        var center: (Double, Double) { (Double(x) + Double(w) / 2, Double(y) + Double(h) / 2) }
    }

    /// Gap left between quadrants (and against the top of the screen).
    static let margin = 2

    /// Which quadrant fills first once all four are occupied: bottom-right, then
    /// bottom-left, top-right, top-left. Indices into `quadrants(of:)`.
    static let fillOrder = [3, 2, 1, 0]

    /// How much of the window behind is left showing at the top: a Terminal title
    /// bar is ~28 pt tall, so 32 exposes a whole one — the session's name.
    static let titleStep = 32

    /// …and how much at the left: enough for the Claude activity bubble of the
    /// window behind to show, and no more. It is a third of what it was, which is
    /// still two thirds of `titleStep` — the staircase reads diagonally, but its
    /// width comes straight out of the width of every terminal in the pile.
    static let sideStep = 21

    /// The smallest a cascaded window may get, as a divisor of the quadrant: half
    /// the width and half the height, i.e. a quarter of the quadrant's area.
    static let minFraction = 2

    /// How many windows one quadrant piles up before the next quadrant is started.
    /// Seven is a number of title bars the eye still reads as a list.
    static let maxDepth = 7

    /// Steps never fall below this, however crowded a quadrant gets — a step of
    /// zero would hide a window completely behind the one in front of it.
    static let minStep = 6

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

    /// How many windows `quad` holds: `maxDepth`, unless the quadrant is too small
    /// to take that many nominal steps without breaking the `minFraction` floor —
    /// the deepest window plus as many steps as fit in the half of the quadrant
    /// that may be given away, whichever axis runs out first.
    static func depth(in quad: Rect) -> Int {
        let vertical = quad.h / minFraction / titleStep
        let horizontal = quad.w / minFraction / sideStep
        return min(maxDepth, 1 + max(1, min(vertical, horizontal)))
    }

    /// How many windows each quadrant holds, in quadrant order, for `count`
    /// windows on the display. Everyone gets one; the extras then **fill one
    /// quadrant at a time** in `fillOrder` — bottom-right to its `depth`, then
    /// bottom-left, and so on — which is why the bottom of the screen is deep and
    /// the top stays a single window each for as long as possible. Once all four
    /// are full the rest are dealt round-robin and the steps tighten.
    static func capacities(count: Int, display: Rect) -> [Int] {
        var caps = [Int](repeating: 1, count: 4)
        guard count > 4 else { return caps }
        let quads = quadrants(of: display)
        var left = count - 4
        for q in fillOrder where left > 0 {
            let take = min(left, depth(in: quads[q]) - 1)
            caps[q] += take
            left -= take
        }
        var i = 0
        while left > 0 {
            caps[fillOrder[i % 4]] += 1
            left -= 1
            i += 1
        }
        return caps
    }

    /// `count` windows cascading over `quad`, **deepest first**: slot 0 is the
    /// whole quadrant, and each one after it is stepped down-and-right from the
    /// quadrant's top-left corner while its bottom-right corner stays nailed to
    /// the quadrant's own — so the pile shrinks towards that corner and never
    /// spills onto a neighbouring quarter.
    ///
    /// The step is the nominal one (`titleStep` tall, `sideStep` wide) unless the
    /// quadrant is holding more windows than it comfortably fits, in which case it
    /// tightens so the last window still keeps half the quadrant's width and half
    /// its height. Dividing the *available spread* rather than shrinking each
    /// window in turn is what keeps the pile bounded however many terminals are
    /// open.
    static func cascade(count: Int, in quad: Rect) -> [Rect] {
        guard count > 1 else { return count == 1 ? [quad] : [] }
        let steps = count - 1
        let dy = max(minStep, min(titleStep,
                                  quad.h / minFraction / steps,
                                  quad.w * titleStep / sideStep / minFraction / steps))
        let dx = max(1, dy * sideStep / titleStep)
        return (0..<count).map { i in
            let offX = min(i * dx, quad.w / minFraction)
            let offY = min(i * dy, quad.h / minFraction)
            return Rect(x: quad.x + offX, y: quad.y + offY,
                        w: quad.w - offX, h: quad.h - offY)
        }
    }

    /// Every slot on the display, in **layout order**: the four quadrants
    /// (top-left, top-right, bottom-left, bottom-right), each one already piled as
    /// deep as it has to be, deepest window first. Exactly `count` slots come back
    /// once there are more windows than quadrants.
    ///
    /// That order is also the order the windows are raised in, which is why it is
    /// the order the array is in: within a quadrant, raising deepest-to-shallowest
    /// leaves every title bar showing.
    static func targets(count: Int, display: Rect) -> [Rect] {
        let quads = quadrants(of: display)
        guard count > quads.count else { return quads }
        let caps = capacities(count: count, display: display)
        return quads.enumerated().flatMap { cascade(count: caps[$0.offset], in: $0.element) }
    }

    /// The slots worth giving the keyboard: **unobstructed and as large as they
    /// come**. Only the front-most slot of a quadrant has nothing lying on it, so
    /// those four are the candidates; of them, the biggest win. Empty piles make
    /// this the whole quadrant, which is why a focused window is pulled out of a
    /// cascade and onto a quarter of the screen, and why with four windows — four
    /// quadrants, one area — every slot ties and the pin costs no movement.
    ///
    /// Indices into `targets(count:display:)`, in quadrant order, so ties are
    /// broken towards the top-left: the quadrant `fillOrder` reaches last, hence
    /// the one most likely to still be a single window.
    static func topSlots(count: Int, display: Rect) -> [Int] {
        let slots = targets(count: count, display: display)
        guard !slots.isEmpty else { return [] }
        let caps = count > 4 ? capacities(count: count, display: display) : [Int](repeating: 1, count: 4)
        var fronts: [Int] = []
        var index = 0
        for cap in caps where index < slots.count {
            fronts.append(min(index + cap - 1, slots.count - 1))
            index += cap
        }
        let best = fronts.map { slots[$0].w * slots[$0].h }.max() ?? 0
        return fronts.filter { slots[$0].w * slots[$0].h == best }
    }

    /// The slots **nothing can ever cover**: the quadrants holding a single
    /// window, one index each, in quadrant order.
    ///
    /// This is `topSlots` without the tie-break on area — and, more importantly,
    /// without the piles' front slots. A front slot is unobstructed only while its
    /// window is also the front-most of the pile in z-order; these are unobstructed
    /// full stop, because there is nothing else in the quadrant. That is the whole
    /// reason the Claude sessions are given *these* and not the bigger candidate
    /// list: a window promoted here is visible no matter where the ⌘` cycle has
    /// left it standing.
    ///
    /// Empty once every quadrant is piled — roughly eleven windows on a large
    /// screen — at which point the rule quietly stops applying and the layout is
    /// the one geometry gives.
    static func wholeQuadrantSlots(count: Int, display: Rect) -> [Int] {
        let total = targets(count: count, display: display).count
        let caps = count > 4 ? capacities(count: count, display: display)
                             : [Int](repeating: 1, count: 4)
        var out: [Int] = []
        var index = 0
        for cap in caps {
            if cap == 1, index < total { out.append(index) }
            index += cap
        }
        return out
    }

    /// The slots of each quadrant, in quadrant order: the range of
    /// `targets(count:display:)` that one quadrant's pile occupies, deepest slot
    /// first. A quadrant holding a single window gets a one-slot range, which is
    /// what makes the four-window case immune to everything below.
    static func pileSlots(count: Int, display: Rect) -> [Range<Int>] {
        let total = targets(count: count, display: display).count
        let caps = count > 4 ? capacities(count: count, display: display)
                             : [Int](repeating: 1, count: 4)
        var out: [Range<Int>] = []
        var index = 0
        for cap in caps {
            let lo = min(index, total), hi = min(index + cap, total)
            out.append(lo..<hi)
            index += cap
        }
        return out
    }

    /// Re-deal the slots **within each pile** so that depth follows the order the
    /// windows are given in — which is their front-to-back order on screen. The
    /// back-most window of the quadrant gets the deepest slot (the whole quadrant)
    /// and the front-most the smallest step, so the pile reads correctly *without*
    /// anyone having to be raised, and the ⌘` sequence survives the tile.
    ///
    /// Only the depth inside a quadrant is touched; which quadrant a window is in
    /// was decided by geometry and stays decided by geometry. `pinned` — the window
    /// holding the keyboard — keeps the slot the pin gave it and the rest of its
    /// pile is dealt around it, so a focused window is still never buried.
    static func dealPilesByDepth(_ assignment: [Int], count: Int, display: Rect,
                                 pinned: Int? = nil) -> [Int] {
        var out = assignment
        for range in pileSlots(count: count, display: display) where range.count > 1 {
            let members = assignment.indices.filter { range.contains(assignment[$0]) }
            guard members.count > 1 else { continue }
            let fixed = members.contains(where: { $0 == pinned }) ? pinned : nil
            let free = range.filter { slot in fixed.map { assignment[$0] != slot } ?? true }
            // Back-most window first, deepest slot first.
            for (w, slot) in zip(members.filter { $0 != fixed }.sorted(by: >), free) {
                out[w] = slot
            }
        }
        return out
    }

    /// Which slot each window goes to, as an index into `targets(count:display:)`
    /// — in the same order as `windows`, which is their **front-to-back order on
    /// screen**: geometry picks the quadrant, and the pile inside it is then dealt
    /// by that order (`dealPilesByDepth`). `focused` is the window holding the
    /// keyboard, if it is one of these; it is served first, out of `topSlots`.
    /// `claude` are the windows with a session running in them, served next, out of
    /// the quadrants no other window is in.
    ///
    /// Only `focused` is exempt from the re-deal by depth: a window promoted for
    /// running Claude is by construction alone in its quadrant, i.e. a pile of one,
    /// which the re-deal skips anyway — and one that did *not* fit is an ordinary
    /// member of an ordinary pile and has to be dealt like one, or the stack and
    /// the cascade stop agreeing.
    static func assign(windows: [Rect], display: Rect, focused: Int? = nil,
                       claude: Set<Int> = []) -> [Int] {
        let slots = targets(count: windows.count, display: display)
        let placed = assign(windows: windows, targets: slots,
                            pinning: focused, to: topSlots(count: windows.count, display: display),
                            preferring: claude,
                            to: wholeQuadrantSlots(count: windows.count, display: display))
        return dealPilesByDepth(placed, count: windows.count, display: display, pinned: focused)
    }

    /// Target frame for every window, in the order given.
    static func frames(windows: [Rect], display: Rect, focused: Int? = nil,
                       claude: Set<Int> = []) -> [Rect] {
        guard !windows.isEmpty else { return [] }
        let slots = targets(count: windows.count, display: display)
        return assign(windows: windows, display: display, focused: focused,
                      claude: claude).map { slots[$0] }
    }

    /// Greedy nearest-pair matching: repeatedly take the closest window/slot pair
    /// still unclaimed. Not provably the cheapest total, but **stable**, which is
    /// worth more here — a window already sitting on a slot is at distance 0 and
    /// takes it before any other pair is even considered, so a layout that is
    /// already tiled reproduces itself exactly. Ties break on window order, so the
    /// result never depends on dictionary or timing luck.
    ///
    /// It runs in three rounds, each one over a smaller claim on the screen:
    ///
    /// 1. `pinning` — the focused window takes the cheapest of `candidates`, the
    ///    nearest of the biggest unobstructed slots, before anything else is
    ///    matched. Nearest, not first, so that when the candidates tie (four
    ///    windows, four equal quadrants) the pin lands on the slot the window
    ///    already occupies and re-tiling stays the no-op it is meant to be.
    /// 2. `preferring` — the terminals running a Claude session are matched
    ///    against `visible`, the quadrants nothing is stacked on. Greedy, not in
    ///    window order: taking the cost-0 pairs first is what keeps a screen that
    ///    is already laid out from re-shuffling itself when ⌘` changes which
    ///    session is front-most.
    /// 3. everyone left, over everything left.
    static func assign(windows: [Rect], targets: [Rect],
                       pinning focused: Int? = nil, to candidates: [Int] = [],
                       preferring claude: Set<Int> = [], to visible: [Int] = []) -> [Int] {
        var out = [Int](repeating: -1, count: windows.count)
        var takenSlot = [Bool](repeating: false, count: targets.count)

        if let focused, windows.indices.contains(focused),
           let slot = candidates.filter({ targets.indices.contains($0) })
               .min(by: { cost(windows[focused], targets[$0]) < cost(windows[focused], targets[$1]) }) {
            out[focused] = slot
            takenSlot[slot] = true
        }

        claim(claude.filter { $0 != focused }.sorted(), to: visible,
              windows: windows, targets: targets, out: &out, takenSlot: &takenSlot)
        claim(Array(windows.indices), to: Array(targets.indices),
              windows: windows, targets: targets, out: &out, takenSlot: &takenSlot)
        return out
    }

    /// One greedy round: hand `slots` to `wanted`, cheapest pair first, skipping
    /// whatever an earlier round has already settled. Anything left unmatched —
    /// more windows than slots, which is the normal case for round 2 — simply falls
    /// through to the round after it.
    private static func claim(_ wanted: [Int], to slots: [Int],
                              windows: [Rect], targets: [Rect],
                              out: inout [Int], takenSlot: inout [Bool]) {
        var pairs: [(cost: Int, w: Int, t: Int)] = []
        pairs.reserveCapacity(wanted.count * slots.count)
        for w in wanted where windows.indices.contains(w) && out[w] == -1 {
            for t in slots where targets.indices.contains(t) && !takenSlot[t] {
                pairs.append((cost(windows[w], targets[t]), w, t))
            }
        }
        pairs.sort {
            if $0.cost != $1.cost { return $0.cost < $1.cost }
            if $0.w != $1.w { return $0.w < $1.w }
            return $0.t < $1.t
        }
        for p in pairs where out[p.w] == -1 && !takenSlot[p.t] {
            out[p.w] = p.t
            takenSlot[p.t] = true
        }
    }

    /// How far a window is from a slot: corner distance, plus half the size
    /// mismatch. Corners separate the windows of one pile from each other; the
    /// size term separates a whole quadrant from a window merely sitting in its
    /// top-left corner, which share a corner exactly.
    private static func cost(_ a: Rect, _ b: Rect) -> Int {
        abs(a.x - b.x) + abs(a.y - b.y) + (abs(a.w - b.w) + abs(a.h - b.h)) / 2
    }

}
