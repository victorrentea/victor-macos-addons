import CoreGraphics
import Foundation

/// Which side of the Retina the ASUS travel monitor sits on — a fact about the
/// desk, not about the venue, so it is remembered across plug-ins and every
/// automatic arrangement honours it (the 🖥️ ASUS left / right rows set it, 2026-10-08).
/// Default `.right`, which is what the arrangement always did before.
enum AsusSide: String {
    case left, right

    static let key = "asusSide"

    static var preferred: AsusSide {
        get { UserDefaults.standard.string(forKey: key).flatMap(AsusSide.init) ?? .right }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Read off the live layout: whichever side of the Retina's centre the
    /// ASUS's centre is on.
    static func current(asus: CGRect, retina: CGRect) -> AsusSide {
        asus.midX < retina.midX ? .left : .right
    }

    /// What the ASUS rows read: no ASUS, an ASUS caught in a mirror set (no
    /// side to speak of), or an ASUS sitting on one side.
    enum State: Equatable {
        case absent
        case mirrored
        case at(AsusSide)
    }

    /// The one display to move, and where to. Whichever of the two is **main**
    /// stays put — moving the display at (0,0) would hand the menu bar to the
    /// other one, and "ASUS on the left" must not mean "ASUS loses the menu bar".
    /// Top edges are aligned, as `DisplayArrangementManager` has always done.
    enum Move: Equatable {
        case asus(to: CGPoint)
        case retina(to: CGPoint)
    }

    static func move(to side: AsusSide, asus: CGRect, retina: CGRect, asusIsMain: Bool) -> Move {
        if asusIsMain {
            let x = side == .left ? asus.maxX : asus.minX - retina.width
            return .retina(to: CGPoint(x: x, y: asus.minY))
        }
        let x = side == .left ? retina.minX - asus.width : retina.maxX
        return .asus(to: CGPoint(x: x, y: retina.minY))
    }
}
