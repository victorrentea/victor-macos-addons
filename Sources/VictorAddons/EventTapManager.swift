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
    var onScreenshot: ((_ toClipboard: Bool) -> Void)?
    var onToggleDarkMode: (() -> Void)?
    var onRepaste: (() -> Void)?
    var onOpenCatalog: (() -> Void)?
    var onTileTerminals: (() -> Void)?
    var onClaudeWorkspaceHotkey: (() -> Void)?
    var onMouseButton5Pressed: (() -> Void)?
    var onAppendClipboardToNotes: (() -> Void)?
    var onCopySelectionToNotes: (() -> Void)?
    /// Plain Ctrl+V — the paste passes through; the app advances the clipboard
    /// image stack to the next image after a short delay.
    var onCtrlVPaste: (() -> Void)?
    var onOpenCalendar: (() -> Void)?
    var onWhip: (() -> Void)?
    var onWhipCrack: (() -> Void)?   // Enter / extra mouse button, while the whip overlay is up
    var onModifierFlagsChanged: ((_ option: Bool, _ shift: Bool) -> Void)?
    var onKeyDownWhileOptionHeld: (() -> Void)?

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

    /// Bundle id of the focused app, cached from the main thread via an NSWorkspace
    /// notification so the tap callback can read it without touching AppKit
    /// off-thread.
    private let frontmostLock = NSLock()
    private var frontmostBundleId: String?

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
            self.setFrontmostBundleId(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.setFrontmostBundleId(app?.bundleIdentifier)
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
            DispatchQueue.main.async { [weak self] in self?.onModifierFlagsChanged?(hasOpt, hasShift) }
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

        // Cmd+scroll over a terminal → strip Cmd so it scrolls the scrollback
        // like a plain wheel. macOS screen-zoom is Ctrl+scroll (not Cmd) and
        // Terminal/iTerm2 don't map Cmd+scroll to font-zoom — and we remove Cmd
        // before the terminal even sees the event, so this can never zoom.
        // Targets the app under the CURSOR (where the scroll lands), not focus.
        // Cmd+scroll while a terminal is focused → zoom the font (Cmd+= / Cmd+-)
        // instead of scrolling. Suppress the scroll and synthesize the native
        // Bigger/Smaller shortcut, one step per wheel notch.
        if type == .scrollWheel {
            guard event.flags.contains(.maskCommand),
                  let bundle = currentFrontmostBundleId(),
                  scrollScopeBundleIds.contains(bundle) else {
                return Unmanaged.passUnretained(event)
            }
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)  // + up, - down
            if dy != 0 {
                // Reset on direction change so a reversal responds immediately.
                if (dy > 0) != (zoomAccumulator > 0) { zoomAccumulator = 0 }
                zoomAccumulator += dy
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

        if hasOpt {
            DispatchQueue.main.async { [weak self] in self?.onKeyDownWhileOptionHeld?() }
        }

        // While the 🔥 whip overlay is up, Enter cracks it (the button Victor uses
        // to submit to Claude often *is* an Enter). Always pass the key through so
        // the Enter still reaches Claude — this only adds the crack, never eats it.
        if whipOverlayShowing && (keyCode == VK_RETURN || keyCode == VK_KEYPAD_ENTER) {
            DispatchQueue.main.async { [weak self] in self?.onWhipCrack?() }
            return Unmanaged.passUnretained(event)
        }

        // Ctrl+P → screenshot to clipboard, Ctrl+Shift+P → screenshot to file (suppress)
        if keyCode == VK_P && hasCtrl && !hasCmd && !hasOpt {
            let toClipboard = !hasShift
            DispatchQueue.global().async { [weak self] in self?.onScreenshot?(toClipboard) }
            return nil
        }

        // Cmd+Opt+Ctrl+D → toggle dark mode (suppress)
        if keyCode == VK_D && hasCmd && hasCtrl && hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onToggleDarkMode?() }
            return nil
        }

        // Cmd+Opt+Ctrl+C → open Claude Code in ~/workspace (suppress)
        if keyCode == VK_C && hasCmd && hasCtrl && hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onClaudeWorkspaceHotkey?() }
            return nil
        }

        // Cmd+Ctrl+C → open catalog (suppress)
        if keyCode == VK_C && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onOpenCatalog?() }
            return nil
        }

        // Cmd+Opt+C → open Google Calendar in Chrome, snapped to the Retina
        // display (suppress)
        if keyCode == VK_C && hasCmd && hasOpt && !hasCtrl {
            DispatchQueue.global().async { [weak self] in self?.onOpenCalendar?() }
            return nil
        }

        // Ctrl+Opt+C → copy current selection and append it to session notes
        // (sibling of Ctrl+Opt+V, which appends the existing clipboard) (suppress)
        if keyCode == VK_C && hasCtrl && hasOpt && !hasCmd {
            DispatchQueue.global().async { [weak self] in self?.onCopySelectionToNotes?() }
            return nil
        }

        // Cmd+Ctrl+A → tile Terminal windows (suppress)
        if keyCode == VK_A && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onTileTerminals?() }
            return nil
        }

        // Ctrl+W → 🔥 WIP Agent (whip Claude) (suppress). NB: this globally
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
        return NSPasteboard.general.string(forType: .string)
    }

    // MARK: - Frontmost app tracking (for Cmd+scroll zoom targeting)

    private func setFrontmostBundleId(_ id: String?) {
        frontmostLock.lock(); frontmostBundleId = id; frontmostLock.unlock()
    }

    private func currentFrontmostBundleId() -> String? {
        frontmostLock.lock(); defer { frontmostLock.unlock() }
        return frontmostBundleId
    }
}
