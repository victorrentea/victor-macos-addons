import Foundation

/// One key, two screenshots: a tap of ⌃P is the whole screen, a *hold* is the
/// crosshair crop that ⌃⇧P used to be.
///
/// **Nothing fires on the keyDown** — which of the two you meant is answered on
/// the *release*: under `holdSeconds` takes the screen, over it opens the
/// crosshair. (An **autorepeat** keyDown answers it earlier, so on a Mac with
/// key repeat on the crosshair appears while the key is still down, which is
/// what a hold should feel like; the keyUp is the fallback where repeat is off.)
///
/// The first version did fire the full-screen shot on the keyDown, to keep a tap
/// free of any "is this a hold?" delay. That delay is not what it costs, though:
/// waiting for the *release* costs only the length of the keypress itself — some
/// 100 ms for a tap — while firing early meant a hold always took a full screen
/// nobody asked for, and flashed a whole-screen yellow border over the crosshair
/// that was already waiting for the drag.
enum ScreenshotHoldPolicy {
    /// Long enough that a normal tap (~80–150 ms) can never reach it, short
    /// enough that "hold it a moment" is one motion rather than a wait.
    static let holdSeconds: TimeInterval = 0.45

    static func isHold(pressDuration: TimeInterval) -> Bool {
        pressDuration >= holdSeconds
    }
}
