import CoreGraphics
import Foundation

enum KeySimulator {
    private static let VK_COMMAND: CGKeyCode = 0x37
    private static let VK_CONTROL: CGKeyCode = 0x3B
    private static let VK_OPTION: CGKeyCode  = 0x3A

    /// Post a modified keystroke the way a human types it: the modifier key goes
    /// **down as its own event**, then the key, then the modifier comes back up
    /// with the flags cleared.
    ///
    /// The obvious shortcut — one bare key event carrying `flags = .maskCommand`
    /// — has a nasty side effect that took a while to find: it **latches that
    /// modifier in the system's event-source state indefinitely**. Measured: with
    /// no keys touched, `CGEventSource.flagsState` reads 0; post one ⌘-flagged
    /// key event and *every* process reads command-held from then until the next
    /// real keystroke clears it. That is what made `waitForModifiersReleased`
    /// answer "still held" forever after the first synthetic paste, and it means
    /// any code (ours or another app's) that consults modifier state was being
    /// told a lie by us. Ending on a flags-cleared modifier keyUp leaves the
    /// state at 0 (verified the same way).
    private static func chord(_ keyCode: CGKeyCode, modifier: CGKeyCode, flag: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        post(modifier, down: true, flags: flag)
        post(keyCode, down: true, flags: flag)
        post(keyCode, down: false, flags: flag)
        post(modifier, down: false, flags: [])
    }

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

    /// Which modifier keys are physically held right now.
    ///
    /// This has to be read *before* posting anything of our own — see `chord`:
    /// a flagged bare key event poisons this reading system-wide.
    static func heldModifiers() -> CGEventFlags {
        let watched: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return CGEventSource.flagsState(.hidSystemState).intersection(watched)
    }

    /// Block until no modifier key is physically held (or `timeout` elapses),
    /// returning whether the keyboard actually came clean.
    ///
    /// A synthetic keystroke posted while the user still holds the hotkey's own
    /// modifiers does NOT arrive as the combination we asked for: the window
    /// server merges the live hardware state into it, so a ⌘C posted while ⌘⌃S
    /// is down reaches the frontmost app as **⌃⌘C** — a different shortcut
    /// entirely, and on this Mac a bound one (it makes Wispr Flow put its last
    /// dictation on the clipboard, which is precisely how ⌘⌃S ended up filing a
    /// stale transcript into the notes instead of the fresh copy).
    @discardableResult
    static func waitForModifiersReleased(timeout: TimeInterval = 1.5) -> Bool {
        var waited: TimeInterval = 0
        let step: TimeInterval = 0.02
        while waited < timeout {
            if heldModifiers().isEmpty { return true }
            Thread.sleep(forTimeInterval: step)
            waited += step
        }
        return false
    }

    static func cmdV() { chord(0x09, modifier: VK_COMMAND, flag: .maskCommand) }
    static func cmdC() { chord(0x08, modifier: VK_COMMAND, flag: .maskCommand) }
    static func cmdZ() { chord(0x06, modifier: VK_COMMAND, flag: .maskCommand) }

    /// Cmd+= — terminal "Bigger" (increase font size). Key 0x18 = kVK_ANSI_Equal.
    static func zoomBigger()  { chord(0x18, modifier: VK_COMMAND, flag: .maskCommand) }
    /// Cmd+- — terminal "Smaller" (decrease font size). Key 0x1B = kVK_ANSI_Minus.
    static func zoomSmaller() { chord(0x1B, modifier: VK_COMMAND, flag: .maskCommand) }

    /// Ctrl+Opt+Space — global hotkey that summons ChatGPT. Space = 0x31 (kVK_Space).
    static func simulateCtrlOptSpace() {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
            usleep(12_000)
        }
        post(VK_CONTROL, down: true, flags: .maskControl)
        post(VK_OPTION, down: true, flags: [.maskControl, .maskAlternate])
        post(0x31, down: true, flags: [.maskControl, .maskAlternate])
        post(0x31, down: false, flags: [.maskControl, .maskAlternate])
        post(VK_OPTION, down: false, flags: .maskControl)
        post(VK_CONTROL, down: false, flags: [])
    }
}
