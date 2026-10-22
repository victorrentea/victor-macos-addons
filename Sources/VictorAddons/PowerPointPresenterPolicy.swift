import CoreGraphics

/// One active, non-mirrored display, in global top-left coordinates — the space
/// both `CGDisplayBounds` and the Accessibility position attribute use.
struct PresenterScreen: Equatable {
    let id: UInt32
    let frame: CGRect
    let isBuiltin: Bool
}

/// Pure placement rule for `PowerPointPresenterPlacement`: where Presenter View
/// and the slides belong.
///
/// PowerPoint for Mac has no setting for it once there are 3+ displays. It puts
/// the slides on the external display with the **lowest Quartz id** — the order
/// the cables came up in, not the arrangement in System Settings — and macOS
/// re-deals those ids on every replug or wake. Swapping cables "fixed" it on
/// 2026-10-15; a week later the same rule sent Presenter View to the right DELL.
/// So the decision is made here, by position, every time.
///
/// - Presenter View → the **leftmost external** screen (the left DELL at home,
///   the ASUS on the road whichever side it sits on).
/// - Slides → the **built-in Retina**, the one projected to the room.
enum PowerPointPresenterPolicy {

    static func presenterTarget(_ screens: [PresenterScreen]) -> CGRect? {
        screens.filter { !$0.isBuiltin }.min { $0.frame.minX < $1.frame.minX }?.frame
    }

    /// Only with an external for Presenter View: alone on the laptop, PowerPoint's
    /// own choice is the only one there is.
    static func slidesTarget(_ screens: [PresenterScreen]) -> CGRect? {
        guard presenterTarget(screens) != nil else { return nil }
        return screens.first { $0.isBuiltin }?.frame
    }

    /// A window counts as on a screen when its centre is — PowerPoint sizes both
    /// windows to their screen, so anything else means it is on another one.
    static func isOn(_ target: CGRect, window: CGRect) -> Bool {
        target.contains(CGPoint(x: window.midX, y: window.midY))
    }
}
