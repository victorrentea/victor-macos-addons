import CoreGraphics
import Foundation

enum KeySimulator {
    static func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags   = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Block until no modifier key is physically held (or `timeout` elapses),
    /// returning whether the keyboard actually came clean.
    ///
    /// A synthetic keystroke posted while the user is still holding the hotkey's
    /// own modifiers does NOT arrive as the combination we asked for: the window
    /// server merges the live hardware modifier state into it, so a ⌘C posted
    /// with ⌘⌃S still down lands in the target app as ⌃⌘C — which no app treats
    /// as Copy, so nothing is copied and the caller sees a clipboard that never
    /// moved. Waiting for the fingers to come off is the only reliable fix; the
    /// hand is already lifting by the time the hotkey handler runs, so this
    /// normally costs a few tens of milliseconds.
    @discardableResult
    static func waitForModifiersReleased(timeout: TimeInterval = 1.0) -> Bool {
        let watched: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        var waited: TimeInterval = 0
        let step: TimeInterval = 0.02
        while waited < timeout {
            if CGEventSource.flagsState(.combinedSessionState).intersection(watched).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: step)
            waited += step
        }
        return false
    }

    static func cmdV() { simulateKeyPress(keyCode: 0x09, flags: .maskCommand) }
    static func cmdC() { simulateKeyPress(keyCode: 0x08, flags: .maskCommand) }
    static func cmdZ() { simulateKeyPress(keyCode: 0x06, flags: .maskCommand) }

    /// Cmd+= — terminal "Bigger" (increase font size). Key 0x18 = kVK_ANSI_Equal.
    static func zoomBigger()  { simulateKeyPress(keyCode: 0x18, flags: .maskCommand) }
    /// Cmd+- — terminal "Smaller" (decrease font size). Key 0x1B = kVK_ANSI_Minus.
    static func zoomSmaller() { simulateKeyPress(keyCode: 0x1B, flags: .maskCommand) }

    /// Ctrl+Opt+Space — global hotkey that summons ChatGPT. Space = 0x31 (kVK_Space).
    static func simulateCtrlOptSpace() {
        simulateKeyPress(keyCode: 0x31, flags: [.maskControl, .maskAlternate])
    }
}
