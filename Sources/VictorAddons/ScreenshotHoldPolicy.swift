import Foundation

/// One key, two screenshots: a tap of ⌃P is the whole screen, a *hold* is the
/// crosshair crop that ⌃⇧P used to be.
///
/// The tap must stay free: the full-screen shot fires on the very first keyDown,
/// with nothing deferred and no "is this a hold?" delay in front of it — waiting
/// half a second to find out would reintroduce exactly the latency this feature
/// exists to remove. So a hold is recognised *after the fact*, from either of
/// two signals, whichever the system gives us first:
///
///  - an **autorepeat** keyDown (the crosshair then appears while the key is
///    still down, which is what a hold should feel like), or
///  - the **keyUp**, when the press lasted at least `holdSeconds` — the fallback
///    for a Mac with key repeat turned off, where no repeat ever arrives.
///
/// The price of not deferring is that a hold also produces a full-screen shot;
/// `ScreenshotManager.takeCropScreenshot(supersedeRecentFull:)` deletes it once
/// the crop lands.
enum ScreenshotHoldPolicy {
    /// Long enough that a normal tap (~80–150 ms) can never reach it, short
    /// enough that "hold it a moment" is one motion rather than a wait.
    static let holdSeconds: TimeInterval = 0.45

    static func isHold(pressDuration: TimeInterval) -> Bool {
        pressDuration >= holdSeconds
    }
}
