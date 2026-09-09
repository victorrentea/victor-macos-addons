import CoreGraphics
import Foundation

/// Pure geometry for the crosshair crop: building the dragged rectangle —
/// corner-to-corner, or centred on the start point while ⌥ is held — moving it
/// while ⌘ is held, and keeping it inside the screen it was started on.
///
/// Every decision here is arithmetic, so it is decided here and unit-tested
/// here — the overlay above it only has to draw what this says. Same bargain as
/// `HeartbeatBump` and `HeartbeatDogFollow`.
///
/// All rectangles are in **global Cocoa** coordinates (y up), the space
/// `NSEvent.mouseLocation` and `NSScreen.frame` already speak; the flip into
/// image pixels happens once, at the capture, and nowhere else.
enum CropFlashGeometry {
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The box ⌥ draws: `center` is the point the drag started from and the
    /// mouse is a **corner**, so the rectangle grows in both directions at once
    /// around a fixed middle — the way you frame something you are already
    /// pointing at, instead of hunting for its top-left corner first.
    ///
    /// The screen is honoured *symmetrically*: a half-extent that would push one
    /// edge off `bounds` is cut on **both** sides, because half a box off the
    /// screen is no longer centred on anything. That is why this cannot be
    /// `rect(from:to:)` + `clamped(_:within:)` — clamping one corner keeps the
    /// box on screen but silently moves its middle.
    static func centeredRect(center: CGPoint, corner: CGPoint, within bounds: CGRect) -> CGRect {
        func half(_ reach: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            max(0, min(reach, min(low, high)))
        }
        let halfW = half(abs(corner.x - center.x), center.x - bounds.minX, bounds.maxX - center.x)
        let halfH = half(abs(corner.y - center.y), center.y - bounds.minY, bounds.maxY - center.y)
        return CGRect(x: center.x - halfW, y: center.y - halfH,
                      width: halfW * 2, height: halfH * 2)
    }

    /// The free corner can be dragged anywhere the mouse goes — but the mouse
    /// can walk onto the *next display*, and a selection spanning two screens is
    /// a capture we cannot take (the shot is one display's pixels). So the
    /// corner is held inside the screen the drag started on.
    static func clamped(_ point: CGPoint, within bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// How far the box may actually follow the mouse while ⌘ is held: the raw
    /// delta, cut back on each axis by whatever would push an edge off `bounds`.
    ///
    /// It is computed from the **total** delta since ⌘ went down, never
    /// accumulated tick by tick — that is what makes the box come straight back
    /// when you push it into an edge and pull away again, instead of sticking
    /// there with the overshoot remembered.
    static func clampedTranslation(of rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGVector {
        func axis(_ d: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            // A box wider than the screen has no legal position; pin it to the
            // low edge rather than letting min/max invert.
            guard low <= high else { return low }
            return min(max(d, low), high)
        }
        return CGVector(dx: axis(delta.dx, bounds.minX - rect.minX, bounds.maxX - rect.maxX),
                        dy: axis(delta.dy, bounds.minY - rect.minY, bounds.maxY - rect.maxY))
    }

    /// `rect` shifted by as much of `delta` as `bounds` allows.
    static func moved(_ rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGRect {
        let d = clampedTranslation(of: rect, by: delta, within: bounds)
        return rect.offsetBy(dx: d.dx, dy: d.dy)
    }

    /// Whole points: a selection is described to `screencapture` and to the
    /// cropper in integers, and a half-point edge is a row of blended pixels
    /// nobody asked for. Grown outward, never inward — rounding a crop *smaller*
    /// is how you lose the last letter of the thing you framed.
    static func rounded(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded(.down), minY = rect.minY.rounded(.down)
        return CGRect(x: minX, y: minY,
                      width: (rect.maxX.rounded(.up) - minX),
                      height: (rect.maxY.rounded(.up) - minY))
    }

    /// Where a global-Cocoa selection lands inside a whole-display capture, in
    /// that capture's own pixels.
    ///
    /// Two conversions in one place because they are only ever right together:
    /// Cocoa counts y **up** from the screen's bottom and a `CGImage` counts it
    /// **down** from its top row, and the scale is read off the capture
    /// (`imageWidth / screen.width`) rather than trusted from
    /// `backingScaleFactor` — the picture is the authority on how many pixels a
    /// point bought.
    static func pixelCrop(of rect: CGRect, onScreen screen: CGRect, imageWidth: CGFloat) -> CGRect {
        guard screen.width > 0 else { return .zero }
        let scale = imageWidth / screen.width
        return CGRect(x: (rect.minX - screen.minX) * scale,
                      y: (screen.maxY - rect.maxY) * scale,
                      width: rect.width * scale,
                      height: rect.height * scale).integral
    }

    /// A border thick enough to read, never so thick it swallows a small crop.
    static func borderThickness(for rect: CGRect) -> CGFloat {
        max(4, min(24, min(rect.width, rect.height) * 0.12))
    }
}
