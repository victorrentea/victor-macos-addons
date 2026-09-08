import CoreGraphics
import Foundation

/// Pure split of "move the bottom-left pill by `offset` points" into the two
/// things that actually move: the panel's window, and the pill view inside it.
///
/// The pill rests flush in its screen's bottom-left corner. Moving it by moving
/// the *window* is the obvious implementation, and it is what the sinking exit
/// used to do — but a window that leaves its screen does not disappear: it is
/// drawn on whatever display the arrangement puts there. On this Mac one monitor
/// sits directly ABOVE the built-in retina, so that monitor's bottom edge IS the
/// retina's top edge, and its pill sinking 150 pt "off the bottom" was drawn 60 pt
/// below the retina's top — a pill flashing across the top of the projected screen
/// for the last ~80 ms of every un-hovered prompt offer.
///
/// The rule that fixes it, and the whole content of this type:
///   • **down** — the window does NOT move; the pill slides down inside it and is
///     clipped at the window's (= the screen's) bottom edge. Same look, and not
///     one pixel can land on a neighbouring display.
///   • **up** — the window moves, as before. The rise is 140 pt on a screen a
///     thousand points tall, so it stays home; and the pill must stay *visible*
///     while it floats, which a fixed-height window would clip away.
enum PillPlacement {
    /// How far the window rises from the screen's bottom edge (never negative).
    static func windowRise(offset: CGFloat) -> CGFloat { max(0, offset) }

    /// How far the pill slides down INSIDE that window (never positive).
    static func pillDrop(offset: CGFloat) -> CGFloat { min(0, offset) }

    /// The two always add back up to the offset the caller asked for.
    static func resolves(offset: CGFloat) -> Bool {
        windowRise(offset: offset) + pillDrop(offset: offset) == offset
    }
}
