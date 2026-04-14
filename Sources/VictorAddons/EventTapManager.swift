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
    var onDictationMute: (() -> Void)?
    var onRepaste: (() -> Void)?
    var onOpenCatalog: (() -> Void)?

    // MARK: Key codes
    private let VK_V: CGKeyCode = 0x09
    private let VK_P: CGKeyCode = 0x23
    private let VK_D: CGKeyCode = 0x02
    private let VK_C: CGKeyCode = 0x08

    // MARK: Mouse button numbers
    private let MOUSE_BUTTON_5: Int64 = 4
    private let MOUSE_BUTTON_3: Int64 = 2

    // MARK: Wheel double-click tracking
    private var wheelPendingWork: DispatchWorkItem?
    private let wheelDoubleClickWindow: TimeInterval = 0.35

    // MARK: Tap reference (kept alive for re-enable on timeout)
    private var tapPort: CFMachPort?

    // MARK: - Start

    func start() {
        let eventsOfInterest: CGEventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue)

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
            if button == MOUSE_BUTTON_5 {
                onDictationMute?()
            } else if button == MOUSE_BUTTON_3 {
                handleWheelClick()
            }
            return Unmanaged.passUnretained(event)
        }

        // Keyboard events
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasCmd  = flags.contains(.maskCommand)
        let hasCtrl = flags.contains(.maskControl)
        let hasOpt  = flags.contains(.maskAlternate)

        // Ctrl+P → screenshot (suppress)
        if keyCode == VK_P && hasCtrl && !hasCmd && !hasOpt {
            DispatchQueue.global().async { [weak self] in self?.onScreenshot?() }
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

    // MARK: - Wheel double-click

    private func handleWheelClick() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.wheelPendingWork != nil {
                // Second click within window = double click
                self.wheelPendingWork?.cancel()
                self.wheelPendingWork = nil
                DispatchQueue.global().async { self.onRepaste?() }
            } else {
                // First click — start timer
                let work = DispatchWorkItem { [weak self] in
                    self?.wheelPendingWork = nil
                }
                self.wheelPendingWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + self.wheelDoubleClickWindow, execute: work)
            }
        }
    }

    // MARK: - Clipboard helper

    private func getClipboardText() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}
