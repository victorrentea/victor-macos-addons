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
}
