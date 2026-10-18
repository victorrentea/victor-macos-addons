import ApplicationServices
import Foundation

/// Reads the text currently selected in the frontmost app **without touching the
/// clipboard**, through the in-process Accessibility API — the same grant the
/// event tap and `TerminalTiler` already rely on, so no extra permission.
///
/// This exists because the obvious alternative — simulating ⌘C and watching the
/// pasteboard — is unreliable exactly where it matters: the hotkey's own
/// modifiers are still under the fingers when the synthetic ⌘C is posted, apps
/// answer a no-selection ⌘C inconsistently (some no-op, some copy the whole
/// line), and a copy that never lands is indistinguishable from "nothing was
/// selected", which is what made ⌘⌃S quietly append a stale clipboard.
///
/// Not every app answers: Chrome/Safari/native text views do, some Java and
/// Electron UIs do not. `nil` means "don't know", so callers must keep their
/// ⌘C / clipboard fallbacks rather than treating it as "nothing selected".
enum SelectionReader {
    /// AX calls block the calling thread; a wedged app must not stall the notes
    /// hotkey for the system default (6 s).
    private static let messagingTimeout: Float = 0.3

    static func focusedSelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else {
            return nil
        }
        // An empty selected-text string is a real answer ("nothing is selected"),
        // but it is also what an element that merely *has* the attribute returns
        // when it isn't a text view at all. Both mean "no selection here", so the
        // caller should fall through to its next strategy either way.
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// What the ⌘C fallback did — kept only for the log line, so a wrong
    /// capture can be traced to "the copy never landed" vs "the keys were held".
    struct CopyAttempt {
        /// The hotkey's modifiers came off in time, so the ⌘C was posted.
        var modifiersReleased: Bool
        /// The pasteboard changed after the ⌘C — the app had something to copy.
        var copied: Bool
        var waited: TimeInterval

        var summary: String {
            modifiersReleased
                ? "⌘C \(copied ? "copied" : "no-op") after \(Int(waited * 1000))ms"
                : "modifiers still held — skipped ⌘C, using clipboard"
        }
    }

    /// The fallback for when `focusedSelection()` has no answer (many Java and
    /// Electron UIs don't): a simulated ⌘C — but ONLY once the hotkey's own
    /// modifiers are off the keyboard. A ⌘C posted while ⌘⌃S is still held
    /// arrives at the app as ⌃⌘C, and on this Mac that is a real shortcut: it
    /// makes Wispr Flow replace the clipboard with its last dictation. That was
    /// the whole bug — the fresh copy was overwritten by a stale transcript a
    /// few milliseconds before we read it. So if the fingers are still down
    /// after the wait, we do NOT copy: the clipboard already holds what the user
    /// wants, and the one thing worse than missing a selection is destroying
    /// the clipboard to look for it.
    ///
    /// Either way the caller then reads the clipboard: it holds the selection
    /// if the copy landed, and what it held before if there was nothing to copy.
    /// Blocks up to ~2 s; call off the main thread.
    static func copyWithSimulatedCmdC() -> CopyAttempt {
        guard KeySimulator.waitForModifiersReleased() else {
            return CopyAttempt(modifiersReleased: false, copied: false, waited: 0)
        }
        let before = PasteboardGate.sync { $0.changeCount }
        KeySimulator.cmdC()

        // Wait for the app to service the copy. changeCount bumps on every
        // pasteboard write (even identical content), so this detects whether
        // anything was copied — apps no-op ⌘C when nothing is selected.
        var waited: TimeInterval = 0
        let step: TimeInterval = 0.02
        while PasteboardGate.sync({ $0.changeCount }) == before && waited < 0.5 {
            Thread.sleep(forTimeInterval: step)
            waited += step
        }
        let copied = PasteboardGate.sync { $0.changeCount } != before
        return CopyAttempt(modifiersReleased: true, copied: copied, waited: waited)
    }
}
