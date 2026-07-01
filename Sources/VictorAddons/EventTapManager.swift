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
    var onOpenCalendar: (() -> Void)?
    var onWhip: (() -> Void)?
    var onModifierFlagsChanged: ((_ option: Bool, _ shift: Bool) -> Void)?
    var onKeyDownWhileOptionHeld: (() -> Void)?

    // MARK: Key codes
    private let VK_V: CGKeyCode = 0x09
    private let VK_P: CGKeyCode = 0x23
    private let VK_D: CGKeyCode = 0x02
    private let VK_C: CGKeyCode = 0x08
    private let VK_A: CGKeyCode = 0x00
    private let VK_W: CGKeyCode = 0x0D

    // MARK: Mouse button numbers (CGEvent uses 0-indexed buttonNumber)
    private let MOUSE_BUTTON_3: Int64 = 2  // wheel click
    private let MOUSE_BUTTON_5: Int64 = 4  // "forward" side button — used by Wispr Flow push-to-talk

    // MARK: Wheel click tracking
    private var wheelClickCount: Int = 0
    private var wheelPendingWork: DispatchWorkItem?
    private let wheelClickWindow: TimeInterval = 0.35

    // MARK: Tap reference (kept alive for re-enable on timeout)
    private var tapPort: CFMachPort?
    var isActive: Bool { tapPort != nil }

    // MARK: - Start

    func start() {
        let eventsOfInterest: CGEventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue)

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
}
