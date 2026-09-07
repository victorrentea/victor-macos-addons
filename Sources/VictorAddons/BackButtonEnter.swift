import CoreGraphics
import Foundation

/// The mouse's rear thumb button types **Return**, and ⌘ + that button types
/// **⌘Return**. This replaces **LinearMouse**, uninstalled on 2026-09-07, whose
/// entire `~/.config/linearmouse/linearmouse.json` came down to those two rules
/// on the Logitech Signature M650 L (its other two entries were LinearMouse's
/// own defaults and did nothing).
///
/// It is the button Victor submits to Claude with, dozens of times an hour, so
/// it has to be served by something that is always running — this app is a
/// LaunchAgent, where Walkie Talkie is a login-time app that gets quit whenever
/// its 2.5 GB of Whisper weights are wanted back.
///
/// **Any other modifier passes through untouched.** LinearMouse had no rule for
/// ⌥, ⌃, ⇧ or any combination containing them, so neither has this: the button
/// goes back to being a mouse button and whatever is in front sees it (browsers
/// still go back a page).
///
/// **The device scoping could not be preserved, and that is accepted.**
/// LinearMouse matched the M650 by USB vendor/product id. A `CGEventTap` is
/// handed events after the HID layer has already anonymised them — there is no
/// device on a `CGEvent` — so this applies to *any* mouse's back button. On this
/// Mac there is one mouse, and the built-in trackpad has no such button, so the
/// difference is unobservable.
///
/// **There is no hold to detect, and the reason is a firmware feature rather
/// than a hardware limit.** Measured 2026-09-07 with a passive tap and every
/// remapper on the machine killed: a deliberate two-second hold of either side
/// button (back = 3, forward = 4) reaches the tap as a **4–15 ms down/up pair at
/// the moment of release**, while the wheel on the same mouse reports a 1668 ms
/// hold perfectly in the same window. That asymmetry is the M650 doing something
/// on purpose — holding a side button is its own gesture, turning the wheel into
/// horizontal scrolling, so the firmware **withholds the button event until the
/// finger comes up** and there is nothing left for a tap to time
/// (linearmouse/linearmouse#739). It is disableable in principle, through Logi
/// Options+ or HID++ diversion, and it is not disabled on this Mac. So a click
/// is all that exists here: do not build a hold on these buttons without
/// re-measuring first.
///
/// **Walkie Talkie sees this button before we do, and that is the design.**
/// Both taps are `.cgSessionEventTap` at `.headInsertEventTap`, where the most
/// recently installed tap is first; this app starts at login and the relay
/// starts later, so the relay is ahead. It borrows the back button as a camera
/// shutter *while a dictation is open* and swallows it then — so the only
/// presses that reach here are the ones it did not want, which is exactly the
/// split both apps are written for. Nothing coordinates the two, and nothing
/// should: each simply behaves when the event arrives.
///
/// **Wispr Flow also had this button, and it won.** With Wispr Flow running the
/// Return never arrived; quitting it made the button work — the signature of a
/// tap ahead of ours, and Wispr Flow is launched by hand after login so its tap
/// is always the newer one. Its bindings are in `~/Library/Application
/// Support/Wispr Flow/config.json` (`prefs.user.shortcuts`), keyed by **4096 +
/// CGEvent button number**: `"4099": "ptt"` was the back button held to talk,
/// `"4100": "popo"` the forward button toggling dictation. `4099` was deleted on
/// 2026-09-07 (also from the `prefs.cache.splitKeybinds` mirror) and did not come
/// back across a relaunch; Wispr Flow now has the forward button only. We cannot
/// win this from here: re-inserting our tap to get ahead of Wispr Flow would also
/// put us ahead of Walkie Talkie and break the split above.
enum BackButtonEnter {

    /// CGEvent button numbers are 0-indexed, so the physical "button 4" (the
    /// rear/back thumb button) is 3. Same convention as `EventTapManager`'s
    /// `MOUSE_BUTTON_5` = 4.
    static let buttonNumber: Int64 = 3

    private static let VK_RETURN: CGKeyCode = 0x24

    /// The flags to give the Return, or nil to leave the press alone.
    ///
    /// Bare press → a plain Return. ⌘ held → ⌘Return. Anything else → nil.
    /// Only the four real modifiers are considered: a `CGEvent`'s flags also
    /// carry noise like `maskNonCoalesced`, which is not something the user
    /// pressed.
    static func returnFlags(for flags: CGEventFlags) -> CGEventFlags? {
        let pressed = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if pressed.isEmpty { return [] }
        if pressed == .maskCommand { return .maskCommand }
        return nil
    }

    /// Post the Return. Called on the tap's own run-loop thread, synchronously:
    /// the whole point is a key that lands where a Return would have, and a hop
    /// onto another queue is a window in which the ⌘ being read here can be let
    /// go before the keystroke goes out.
    ///
    /// Posting a ⌘-flagged bare key event normally **latches ⌘ in the system's
    /// event-source state** until the next real keystroke clears it — the trap
    /// `KeySimulator.chord` exists to avoid. It is harmless in this one case and
    /// only in this one case: the user is *physically holding* ⌘ at this instant,
    /// so a real `flagsChanged` clearing the state is already on its way. (The
    /// window server would in fact merge that held ⌘ into a bare Return anyway;
    /// the flag is set explicitly so the result does not depend on it.)
    static func post(flags: CGEventFlags) {
        KeySimulator.simulateKeyPress(keyCode: VK_RETURN, flags: flags)
    }
}
