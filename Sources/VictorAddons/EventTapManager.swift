import AppKit
import CoreGraphics
import Foundation

// MARK: - File-level C callback (no captures allowed)

private let tapCallbackFunc: CGEventTapCallBack = { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
    guard let ptr = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<EventTapManager>.fromOpaque(ptr).takeUnretainedValue()
    return manager.handleEvent(proxy: proxy, type: type, event: event)
}

// MARK: - EventTapManager

class EventTapManager {

    // MARK: Callbacks (set before calling start())
    var onCaptureClipboard: ((String) -> Void)?
    var onEmotionalPaste: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onToggleDarkMode: (() -> Void)?
    var onRepaste: (() -> Void)?
    var onTileTerminals: (() -> Void)?
    var onClaudeWorkspaceHotkey: (() -> Void)?
    /// ⌘⌃Q — Claude Code with `--dangerously-skip-permissions` (Victor's `cx`).
    var onClaudeBypassHotkey: (() -> Void)?
    var onPlainTerminalHotkey: (() -> Void)?
    var onMouseButton5Pressed: (() -> Void)?
    var onAppendClipboardToNotes: (() -> Void)?
    var onCopySelectionToNotes: (() -> Void)?
    /// Plain Ctrl+V — the paste passes through; the app advances the clipboard
    /// image stack to the next image after a short delay.
    var onCtrlVPaste: (() -> Void)?
    var onOpenCalendar: (() -> Void)?
    var onOpenGmail: (() -> Void)?
    var onOpenCatalog: (() -> Void)?
    /// ⌘⌃Z — paste Victor's personal Zoom room link.
    var onPasteZoomLink: (() -> Void)?
    /// ⌘⌃E — paste Victor's email address.
    var onPasteEmail: (() -> Void)?
    /// ⌘⌃R — paste the company's invoicing details (name / VAT code / address).
    var onPasteCompanyDetails: (() -> Void)?
    /// ⌘⌃N — open the "notes" Google Doc in Chrome.
    var onOpenNotesDoc: (() -> Void)?
    var onWhip: (() -> Void)?
    var onWhipCrack: (() -> Void)?   // Enter / extra mouse button, while the whip overlay is up
    var onModifierFlagsChanged: ((_ option: Bool, _ shift: Bool, _ command: Bool, _ control: Bool) -> Void)?
    var onKeyDownWhileModifierHeld: (() -> Void)?

    /// Set on the main thread whenever the 🔥 whip overlay shows/hides. While
    /// true, an Enter (Return / keypad-Enter) or an extra mouse button (6/7)
    /// cracks the whip via `onWhipCrack` — the event still passes through, so
    /// the Enter reaches Claude. Outside the overlay these inputs are untouched.
    var whipOverlayShowing = false

    // MARK: Key codes
    private let VK_V: CGKeyCode = 0x09
    private let VK_P: CGKeyCode = 0x23
    private let VK_D: CGKeyCode = 0x02
    private let VK_C: CGKeyCode = 0x08
    private let VK_A: CGKeyCode = 0x00
    private let VK_W: CGKeyCode = 0x0D
    private let VK_T: CGKeyCode = 0x11
    private let VK_K: CGKeyCode = 0x28
    private let VK_L: CGKeyCode = 0x25
    private let VK_G: CGKeyCode = 0x05
    private let VK_S: CGKeyCode = 0x01
    private let VK_Q: CGKeyCode = 0x0C
    private let VK_Z: CGKeyCode = 0x06
    private let VK_E: CGKeyCode = 0x0E
    private let VK_R: CGKeyCode = 0x0F
    private let VK_N: CGKeyCode = 0x2D
    private let VK_F8: CGKeyCode = 0x64
    private let VK_RETURN: CGKeyCode = 0x24       // Return
    private let VK_KEYPAD_ENTER: CGKeyCode = 0x4C // Enter (keypad / Fn-Return)

    // MARK: Mouse button numbers (CGEvent uses 0-indexed buttonNumber)
    private let MOUSE_BUTTON_3: Int64 = 2  // wheel click
    private let MOUSE_BUTTON_5: Int64 = 4  // "forward" side button — used by Wispr Flow push-to-talk
    private let MOUSE_BUTTON_6: Int64 = 5  // extra side button (physical "button 6")
    private let MOUSE_BUTTON_7: Int64 = 6  // extra side button (physical "button 7")

    // MARK: Wheel click tracking
    private var wheelClickCount: Int = 0
    private var wheelPendingWork: DispatchWorkItem?
    private let wheelClickWindow: TimeInterval = 0.35

    // MARK: Cmd+scroll → terminal font zoom
    /// Terminals where Cmd+scroll is turned into a font-size zoom (Cmd+= / Cmd+-).
    /// Matched against the FOCUSED app, because the synthesized zoom keystroke is
    /// delivered to the key window.
    private let scrollScopeBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]
    /// Accumulates wheel line-delta so one notch = one font step regardless of how
    /// many scroll events a notch emits. Touched only on the tap's run-loop thread
    /// (events are handled serially there), so no lock needed.
    private var zoomAccumulator: Double = 0

    /// Bundle id + pid of the focused app, cached from the main thread via an
    /// NSWorkspace notification so the tap callback can read them without touching
    /// AppKit off-thread. The pid is what `TerminalZoomSizeLock` addresses the
    /// window through.
    private let frontmostLock = NSLock()
    private var frontmostBundleId: String?
    private var frontmostPid: pid_t?

    // MARK: Tap reference (kept alive for re-enable on timeout)
    private var tapPort: CFMachPort?
    var isActive: Bool { tapPort != nil }

    // MARK: - Start

    func start() {
        let eventsOfInterest: CGEventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.scrollWheel.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: tapCallbackFunc,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else {
            overlayError("EventTapManager: Could not create event tap — check Accessibility permissions")
            return
        }
        tapPort = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "EventTapRunLoop"
        thread.start()

        // Track the focused app on the main thread so the tap can cheaply decide
        // (without touching AppKit off-thread) whether Cmd+scroll should zoom.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.setFrontmost(NSWorkspace.shared.frontmostApplication)
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.setFrontmost(app)
            }
        }
    }

    // MARK: - Internal event handler (called from C callback)

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent?) -> Unmanaged<CGEvent>? {
        // Re-enable tap if disabled by system timeout
        if type.rawValue == 0xFFFFFFFE {  // kCGEventTapDisabledByTimeout
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return event.map { Unmanaged.passUnretained($0) }
        }

        guard let event = event else { return nil }

        if type == .flagsChanged {
            let flags = event.flags
            let hasOpt = flags.contains(.maskAlternate)
            let hasShift = flags.contains(.maskShift)
            let hasCmdFlag = flags.contains(.maskCommand)
            let hasCtrlFlag = flags.contains(.maskControl)
            DispatchQueue.main.async { [weak self] in
                self?.onModifierFlagsChanged?(hasOpt, hasShift, hasCmdFlag, hasCtrlFlag)
            }
            return Unmanaged.passUnretained(event)
        }

        // Mouse events
        if type == .otherMouseDown {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if button == MOUSE_BUTTON_3 {
                handleWheelDown()
            } else if button == MOUSE_BUTTON_5 {
                // Pass the event through — Wispr Flow needs to see it. We only
                // observe so the audio mute poll can briefly run at 100ms.
                DispatchQueue.global().async { [weak self] in self?.onMouseButton5Pressed?() }
            } else if whipOverlayShowing && (button == MOUSE_BUTTON_6 || button == MOUSE_BUTTON_7) {
                // Extra side button while the whip is up → crack it (pass through).
                DispatchQueue.main.async { [weak self] in self?.onWhipCrack?() }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseUp {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if button == MOUSE_BUTTON_3 {
                handleWheelUp()
            }
            return Unmanaged.passUnretained(event)
        }

        // Cmd+scroll while a terminal is focused → zoom the font (Cmd+= / Cmd+-)
        // instead of scrolling. Suppress the scroll and synthesize the native
        // Bigger/Smaller shortcut, one step per wheel notch. `TerminalZoomSizeLock`
        // pins the window's frame across the gesture — left alone, the terminal
        // keeps its character grid and resizes the *window* around the new font,
        // which throws away a placement that was deliberate (tiled, or sized to the
        // projector). It must be told BEFORE the keystroke goes out, so the frame it
        // captures is still the pre-zoom one.
        if type == .scrollWheel {
            guard event.flags.contains(.maskCommand),
                  let front = currentFrontmost(),
                  scrollScopeBundleIds.contains(front.bundleId) else {
                return Unmanaged.passUnretained(event)
            }
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)  // + up, - down
            if dy != 0 {
                // Reset on direction change so a reversal responds immediately.
                if (dy > 0) != (zoomAccumulator > 0) { zoomAccumulator = 0 }
                zoomAccumulator += dy
                if zoomAccumulator >= 1 || zoomAccumulator <= -1 {
                    TerminalZoomSizeLock.beforeZoomStep(pid: front.pid)
                }
                while zoomAccumulator >= 1 { zoomAccumulator -= 1; KeySimulator.zoomSmaller() }
                while zoomAccumulator <= -1 { zoomAccumulator += 1; KeySimulator.zoomBigger() }
            }
            return nil  // eat the scroll so the terminal never scrolls
        }

        // Keyboard events
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasCmd   = flags.contains(.maskCommand)
        let hasCtrl  = flags.contains(.maskControl)
        let hasOpt   = flags.contains(.maskAlternate)
        let hasShift = flags.contains(.maskShift)

        // A key pressed under either cheat-sheet's modifiers means the hold was a
        // real shortcut, not a "remind me what's here" pause — drop the overlay.
        if hasOpt || (hasCmd && hasCtrl) {
            DispatchQueue.main.async { [weak self] in self?.onKeyDownWhileModifierHeld?() }
        }

        // ⌥ / ⌥⇧ emoji layer (`EmojiKeyLayer`) — the app types the character
        // instead of the .keylayout, so adding one no longer costs a re-login.
        //
        // The event is REWRITTEN, not swallowed-and-replaced: a synthetic
        // keystroke posted from here would re-enter our own tap and would be
        // merged with the ⌥ the user is still physically holding (see the flag
        // -latching note on `KeySimulator.chord`). Mutating in place is what a
        // keyboard layout does conceptually, and keeps this to one event.
        //
        // ⌥ must be cleared off the event too. Left on, the character arrives
        // flagged as a ⌥ chord and apps route it to a menu equivalent instead of
        // inserting it.
        if hasOpt, !hasCmd, !hasCtrl {
            let text = EmojiKeyLayer.output(keyCode: Int(keyCode), shift: hasShift)
            EmojiKeyLayer.noteObserved(keyCode: Int(keyCode), shift: hasShift, matched: text != nil, text: text)
            if let text {
                let utf16 = Array(text.utf16)
                event.flags = flags.subtracting([.maskAlternate, .maskShift])
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                return Unmanaged.passUnretained(event)
            }
        }

        // While the 🔥 whip overlay is up, Enter cracks it (the button Victor uses
        // to submit to Claude often *is* an Enter). Always pass the key through so
        // the Enter still reaches Claude — this only adds the crack, never eats it.
        if whipOverlayShowing && (keyCode == VK_RETURN || keyCode == VK_KEYPAD_ENTER) {
            DispatchQueue.main.async { [weak self] in self?.onWhipCrack?() }
            return Unmanaged.passUnretained(event)
        }

        // ⌃P → screenshot (suppressed): clipboard AND /tmp/victor-screenshots,
        // always both. ⌃⇧P is deliberately NOT bound — it used to be the
        // "save to the session folder" half of this feature, and with one
        // shortcut doing both there is nothing left for it to mean, so the
        // combination goes back to the focused app (VS Code's Command Palette).
        if keyCode == VK_P && hasCtrl && !hasCmd && !hasOpt && !hasShift {
            DispatchQueue.global().async { [weak self] in self?.onScreenshot?() }
            return nil
        }

        // Cmd+Opt+Ctrl+D → toggle dark mode (suppress)
        if keyCode == VK_D && hasCmd && hasCtrl && hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onToggleDarkMode?() }
            return nil
        }

        // F8 → open Claude Code in ~/workspace (suppress). Bare F8, not fn+F8:
        // this Mac runs F1–F12 as standard function keys, so the key arrives as
        // a real keyDown rather than a media-key system event.
        if keyCode == VK_F8 && !hasCmd && !hasCtrl && !hasOpt && !hasShift {
            DispatchQueue.global().async { [weak self] in self?.onClaudeWorkspaceHotkey?() }
            return nil
        }

        // Cmd+Ctrl+T → open a plain (empty) Terminal in ~/workspace (suppress)
        if keyCode == VK_T && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onPlainTerminalHotkey?() }
            return nil
        }

        // Cmd+Ctrl+C → open Claude Code in a new Terminal on the Retina — the same
        // action as F8 (suppress). This used to open Catalog.docx, which now lives
        // in the menu ("Catalog", under 🖥️ Arrange Monitors): a catalog is looked
        // up occasionally and can afford a menu click, while starting Claude is the
        // thing wanted in a hurry, mid-talk.
        if keyCode == VK_C && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onClaudeWorkspaceHotkey?() }
            return nil
        }

        // Cmd+Ctrl+Q → open Claude Code with permissions bypassed (`cx`) in a new
        // Terminal (suppress). NB this shadows macOS's own ⌃⌘Q "Lock Screen";
        // the session tap sees the key first and swallows it, so the Mac no
        // longer locks on that combination.
        if keyCode == VK_Q && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onClaudeBypassHotkey?() }
            return nil
        }

        // Cmd+Ctrl+K → open the training Catalog.docx in Word (suppress). K, not
        // the T of "training": ⌘⌃T is the Terminal and is used far more often.
        if keyCode == VK_K && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onOpenCatalog?() }
            return nil
        }

        // Cmd+Ctrl+G → open Gmail in Chrome (suppress). G for Gmail, which is what
        // the hand reaches for; it used to be ⌘⌃M.
        if keyCode == VK_G && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onOpenGmail?() }
            return nil
        }

        // Cmd+Ctrl+L → open Google Calendar in Chrome (suppress). Same action as
        // ⌘⌥C below, which keeps working; this one joins the ⌘⌃ cheat-sheet.
        if keyCode == VK_L && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onOpenCalendar?() }
            return nil
        }

        // Cmd+Opt+C → open Google Calendar in Chrome, snapped to the Retina
        // display (suppress)
        if keyCode == VK_C && hasCmd && hasOpt && !hasCtrl {
            DispatchQueue.global().async { [weak self] in self?.onOpenCalendar?() }
            return nil
        }

        // Cmd+Ctrl+S → copy current selection and append it to session notes
        // (sibling of Ctrl+Opt+V, which appends the existing clipboard) (suppress).
        // Moved off ⌃⌥C so it joins the ⌘⌃ cheat-sheet, where it is discoverable.
        if keyCode == VK_S && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onCopySelectionToNotes?() }
            return nil
        }

        // Cmd+Ctrl+Z → paste the Zoom room link (suppress). NB this shadows the
        // usual ⌃⌘Z in whatever app is focused; nothing standard lives there.
        if keyCode == VK_Z && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onPasteZoomLink?() }
            return nil
        }

        // Cmd+Ctrl+E → paste Victor's email address (suppress)
        if keyCode == VK_E && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onPasteEmail?() }
            return nil
        }

        // Cmd+Ctrl+R → paste the company's invoicing details (suppress). This
        // took ⌘⌃R off the 🔁 Restart menu item, which is now click-only: two
        // actions cannot answer the same combination, and the invoicing block is
        // asked for far more often than a wedged app needs restarting.
        if keyCode == VK_R && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onPasteCompanyDetails?() }
            return nil
        }

        // Cmd+Ctrl+N → open the "notes" Google Doc in Chrome (suppress).
        if keyCode == VK_N && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onOpenNotesDoc?() }
            return nil
        }

        // Cmd+Ctrl+A → tile Terminal windows (suppress)
        if keyCode == VK_A && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onTileTerminals?() }
            return nil
        }

        // Ctrl+W → 🔥 Whip (interrupt Claude) (suppress). NB: this globally
        // shadows Ctrl+W's usual "delete word backwards" in terminals/editors.
        if keyCode == VK_W && hasCtrl && !hasCmd && !hasOpt && !hasShift {
            DispatchQueue.global().async { [weak self] in self?.onWhip?() }
            return nil
        }

        // V variants below
        guard keyCode == VK_V else {
            return Unmanaged.passUnretained(event)
        }

        // Ctrl+Opt+V → append clipboard to session notes (suppress)
        if hasCtrl && hasOpt && !hasCmd {
            DispatchQueue.global().async { [weak self] in self?.onAppendClipboardToNotes?() }
            return nil
        }

        // Cmd+Ctrl+V → emotional paste (suppress)
        if hasCmd && hasCtrl {
            DispatchQueue.global().async { [weak self] in self?.onEmotionalPaste?() }
            return nil
        }

        // Cmd+V → capture clipboard (pass through)
        if hasCmd && !hasCtrl {
            if let text = getClipboardText() {
                let captured = text
                DispatchQueue.global().async { [weak self] in self?.onCaptureClipboard?(captured) }
            }
        }

        // Ctrl+V → pass the paste through, then advance the clipboard image stack
        // to the next-older image (after a short delay so this paste reads the
        // current image first). No-op when the stack is empty.
        if hasCtrl && !hasCmd && !hasOpt && !hasShift {
            DispatchQueue.global().async { [weak self] in self?.onCtrlVPaste?() }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Wheel click (double = Claude Desktop opt-opt)

    private func handleWheelDown() {}

    private func handleWheelUp() {
        DispatchQueue.main.async { [weak self] in self?.handleShortWheelClick() }
    }

    private func handleShortWheelClick() {
        wheelPendingWork?.cancel()
        wheelPendingWork = nil
        wheelClickCount += 1

        let count = wheelClickCount
        let work = DispatchWorkItem { [weak self] in
            self?.wheelClickCount = 0
            self?.wheelPendingWork = nil
            if count == 2 {
                DispatchQueue.global().async { [weak self] in self?.onRepaste?() }
            }
        }
        wheelPendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wheelClickWindow, execute: work)
    }

    // MARK: - Clipboard helper

    private func getClipboardText() -> String? {
        // Runs on the EventTapRunLoop thread — must go through the gate
        // (raced the clip-stack poller → 2026-07-22 workshop crashes).
        return PasteboardGate.sync { $0.string(forType: .string) }
    }

    // MARK: - Frontmost app tracking (for Cmd+scroll zoom targeting)

    private func setFrontmost(_ app: NSRunningApplication?) {
        frontmostLock.lock()
        frontmostBundleId = app?.bundleIdentifier
        frontmostPid = app?.processIdentifier
        frontmostLock.unlock()
    }

    private func currentFrontmost() -> (bundleId: String, pid: pid_t)? {
        frontmostLock.lock(); defer { frontmostLock.unlock() }
        guard let bundleId = frontmostBundleId, let pid = frontmostPid else { return nil }
        return (bundleId, pid)
    }
}
