import AppKit
import Foundation

/// Which keystroke the ⌘⇧V bezel posts to paste the clip it is holding.
///
/// **Why there is a choice at all: ⌘V cannot carry a picture into a terminal.**
/// Terminal.app answers ⌘V by writing the pasteboard's *text* to the pty, and an
/// image clip has none — the keystroke lands and nothing appears. Claude Code
/// knows this and reads the clipboard itself instead: its `chat:imagePaste`
/// action, bound to **⌃V**, shells out to `osascript -e 'the clipboard as «class
/// PNGf»'`, saves the PNG and attaches it (verified 2026-09-22 in the strings of
/// `claude` 2.1.278, which also prints the hint *"Paste images into Claude Code
/// using control+v (not cmd+v!)"*). So a ⌃P screenshot walked to in the bezel
/// reaches a Claude prompt only if the bezel presses ⌃V.
///
/// **Text keeps ⌘V.** Claude's ⌃V does fall back to clipboard text when there is
/// no image, but for text ⌘V already works, goes through Terminal's bracketed
/// paste, and needs no subprocess — swapping it would trade a path that works for
/// one that merely also works. The change is scoped to the case that is broken.
///
/// **And ⌃V is only safe where something is listening for it.** To a shell it is
/// readline's `quoted-insert`: it swallows the next keystroke, and in Copilot CLI
/// — which has no clipboard-image path of any kind (checked 2026-09-22: its
/// binary carries no clipboard read beyond `copyToClipboard`) — it is not bound
/// to anything either. Hence both halves of the test below: the frontmost app is
/// Terminal.app *and* its focused window is wearing Claude's spinner. Anywhere
/// else the bezel does exactly what it did before, including the terminal case
/// where ⌘V quietly does nothing — a no-op is better than a swallowed keystroke.
enum ClipboardPasteKeystroke: Equatable {
    /// ⌘V — the pasteboard read by whatever app is in front.
    case command
    /// ⌃V — Claude Code's `chat:imagePaste`.
    case control

    /// Apps that get considered for ⌃V. Terminal.app alone, like
    /// `TerminalPromptKeys.scopeBundleIds`: it is the only terminal on this Mac,
    /// and the window title — the only thing a session can be recognised by —
    /// is read through AX in a way that is Terminal-shaped.
    static let scopeBundleIds: Set<String> = ["com.apple.Terminal"]

    /// - Parameter focusedWindowTitle: the title of the *focused* window of the
    ///   frontmost app, which is where the keystroke is about to land.
    static func choose(isImage: Bool,
                       frontmostBundleID: String?,
                       focusedWindowTitle: String?) -> ClipboardPasteKeystroke {
        guard isImage,
              let bundleID = frontmostBundleID, scopeBundleIds.contains(bundleID),
              ClaudeSessionTitle.isClaudeSession(title: focusedWindowTitle) else {
            return .command
        }
        return .control
    }

    /// Post it. Both halves wait for the hand to come off the hotkey first — see
    /// `KeySimulator.waitForModifiersReleased`.
    func post() {
        switch self {
        case .command: KeySimulator.cmdV()
        case .control: KeySimulator.ctrlV()
        }
    }
}

/// The app (and window) a paste is about to land in, read while the bezel is
/// still up.
///
/// It has to be sampled on the main thread *before* the paste is dispatched: the
/// bezel is a `.nonactivatingPanel`, so the frontmost app never stopped being the
/// one Victor was typing in, but AX and `NSWorkspace` are both main-thread reads
/// and the paste itself runs on a background queue (it sleeps waiting for
/// modifiers).
@MainActor
enum ClipboardPasteTarget {
    struct Snapshot {
        let bundleID: String?
        let focusedWindowTitle: String?
    }

    static func current() -> Snapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return Snapshot(bundleID: nil, focusedWindowTitle: nil)
        }
        let bundleID = app.bundleIdentifier
        guard let bundleID, ClipboardPasteKeystroke.scopeBundleIds.contains(bundleID) else {
            // Nothing else is ever asked for its window title: an AX round trip
            // costs a hop into another process, and outside the scope above the
            // answer cannot change the keystroke.
            return Snapshot(bundleID: bundleID, focusedWindowTitle: nil)
        }
        let window = AXWindows.focusedWindow(pid: app.processIdentifier)
        return Snapshot(bundleID: bundleID,
                        focusedWindowTitle: window.flatMap { AXWindows.title(of: $0) })
    }
}
