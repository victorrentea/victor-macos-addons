import CoreGraphics
import Foundation

/// 🥞 The bottom-left corner holds at most **two** pills, stacked.
///
/// Every `BottomLeftBanner` is its own object (status, prompt offer, paste undo,
/// the alarms, the reminders…) and each used to rest flush in the corner — so
/// two of them up at once were drawn one on top of the other and only the last
/// one could be read. Victor (2026-11-10): *a stack of at most two; the new one
/// comes in at the bottom, the old one climbs, and when a third arrives the top
/// one, if its time is not up yet, rises and fades.*
///
/// So: a pill that **appears** takes slot 0 (flush in the corner, where it always
/// entered) and pushes every pill already up one slot higher; one pushed past the
/// top slot leaves with the rising fade. A pill that **leaves** lets the ones above
/// it slide down, so the stack never has a hole at the bottom. A pill re-shown in
/// place (new text on a pill already up) keeps its slot — it did not arrive.
///
/// This type is the pure part: the order, bottom first, and who gets evicted.
enum BottomLeftStackPolicy {
    static let maxVisible = 2
    /// Vertical gap between two stacked pills.
    static let gap: CGFloat = 6

    /// `new` arrives at the bottom; returns the new order (bottom first) and the
    /// pills pushed out of the top, oldest last.
    static func arrive<T: Equatable>(_ new: T, into order: [T]) -> (order: [T], evicted: [T]) {
        let all = [new] + order.filter { $0 != new }
        return (Array(all.prefix(maxVisible)), Array(all.dropFirst(maxVisible)))
    }

    /// `gone` left; the ones above it drop one slot.
    static func leave<T: Equatable>(_ gone: T, from order: [T]) -> [T] {
        order.filter { $0 != gone }
    }

    /// How far above the screen's bottom edge a pill in `slot` rests.
    static func lift(slot: Int, boxHeight: CGFloat) -> CGFloat {
        CGFloat(slot) * (boxHeight + gap)
    }
}

/// The live stack: which banners are up, bottom first. Main thread only.
enum BottomLeftStack {
    private final class Weak {
        weak var banner: BottomLeftBanner?
        let id: ObjectIdentifier
        init(_ b: BottomLeftBanner) { banner = b; id = ObjectIdentifier(b) }
    }
    private static var order: [Weak] = []

    private static func prune() { order.removeAll { $0.banner == nil } }

    /// A banner is about to appear in the corner: it takes slot 0, the others
    /// climb, the one pushed out of the top is evicted. Returns the lift the new
    /// banner rests at (always slot 0's).
    static func arrive(_ banner: BottomLeftBanner) {
        prune()
        let ids = order.map(\.id)
        let (newIds, evictedIds) = BottomLeftStackPolicy.arrive(ObjectIdentifier(banner), into: ids)
        var byId = Dictionary(uniqueKeysWithValues: order.map { ($0.id, $0) })
        byId[ObjectIdentifier(banner)] = byId[ObjectIdentifier(banner)] ?? Weak(banner)
        let evicted = evictedIds.compactMap { byId[$0]?.banner }
        order = newIds.compactMap { byId[$0] }
        relayout()
        // After the order is settled: an evicted banner's exit calls `leave`,
        // which then finds nothing to remove.
        for b in evicted { b.evictFromStack() }
    }

    /// A banner left the corner (any exit): the ones above it slide down.
    static func leave(_ banner: BottomLeftBanner) {
        let before = order.count
        order.removeAll { $0.id == ObjectIdentifier(banner) || $0.banner == nil }
        if order.count != before { relayout() }
    }

    /// What is up, bottom first, for `/test/banner/buttons?stack=1`: each pill's
    /// text, its slot's resting lift and where its window actually is now.
    static func snapshot() -> [[String: Any]] {
        prune()
        return order.compactMap { $0.banner?.stackDebug }
    }

    private static func relayout() {
        for (slot, w) in order.enumerated() {
            w.banner?.moveToStackLift(BottomLeftStackPolicy.lift(slot: slot,
                                                                 boxHeight: BottomLeftBanner.Style.boxHeight))
        }
    }
}
