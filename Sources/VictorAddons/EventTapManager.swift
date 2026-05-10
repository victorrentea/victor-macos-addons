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
    var onWheelTripleClick: (() -> Void)?
    var onTileTerminals: (() -> Void)?
    var onToggleTranscription: (() -> Void)?
    /// Fired when a likely Wispr-trigger gesture is detected (Mouse5 down, or
    /// Cmd+Opt chord becoming asserted). Used to boost the auto-mute poll.
    var onWisprTriggerHint: (() -> Void)?

    // MARK: Key codes
    private let VK_V: CGKeyCode = 0x09
    private let VK_P: CGKeyCode = 0x23
    private let VK_D: CGKeyCode = 0x02
    private let VK_C: CGKeyCode = 0x08
    private let VK_A: CGKeyCode = 0x00
    private let VK_T: CGKeyCode = 0x11

    // MARK: Mouse button numbers
    private let MOUSE_BUTTON_3: Int64 = 2
    private let MOUSE_BUTTON_5: Int64 = 4

    // MARK: Cmd+Opt chord edge tracking
    private var lastCmdOptHeld: Bool = false

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

        // Mouse events
        if type == .otherMouseDown {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if button == MOUSE_BUTTON_3 {
                handleWheelDown()
            } else if button == MOUSE_BUTTON_5 {
                onWisprTriggerHint?()
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

        // Cmd+Opt chord rising edge → likely Wispr hotkey press
        if type == .flagsChanged {
            let f = event.flags
            let cmdOptHeld = f.contains(.maskCommand) && f.contains(.maskAlternate)
            if cmdOptHeld && !lastCmdOptHeld {
                onWisprTriggerHint?()
            }
            lastCmdOptHeld = cmdOptHeld
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

        // Cmd+Ctrl+C → open catalog (suppress)
        if keyCode == VK_C && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onOpenCatalog?() }
            return nil
        }

        // Cmd+Ctrl+A → tile Terminal windows (suppress)
        if keyCode == VK_A && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onTileTerminals?() }
            return nil
        }

        // Cmd+Ctrl+T → toggle transcription (suppress)
        if keyCode == VK_T && hasCmd && hasCtrl && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onToggleTranscription?() }
            return nil
        }

        // Only Cmd+V variants below
        guard keyCode == VK_V else {
            return Unmanaged.passUnretained(event)
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

    // MARK: - Wheel click (double = Claude Desktop opt-opt, triple = Claude Code terminal)

    private func handleWheelDown() {}

    private func handleWheelUp() {
        DispatchQueue.main.async { [weak self] in self?.handleShortWheelClick() }
    }

    private func handleShortWheelClick() {
        wheelPendingWork?.cancel()
        wheelPendingWork = nil
        wheelClickCount += 1

        if wheelClickCount == 3 {
            wheelClickCount = 0
            DispatchQueue.global().async { [weak self] in self?.onWheelTripleClick?() }
            return
        }

        // Wait before firing: a 3rd click within the window upgrades double → triple
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
