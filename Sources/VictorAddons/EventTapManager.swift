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
    var onDictationEscape: (() -> Void)?
    var onRepaste: (() -> Void)?
    var onOpenCatalog: (() -> Void)?
    var onWheelLongPress: (() -> Void)?
    var onTileTerminals: (() -> Void)?
    var onToggleTranscription: (() -> Void)?
    var onZoomScroll: ((Double) -> Void)?

    // MARK: Key codes
    private let VK_V: CGKeyCode = 0x09
    private let VK_P: CGKeyCode = 0x23
    private let VK_D: CGKeyCode = 0x02
    private let VK_C: CGKeyCode = 0x08
    private let VK_A: CGKeyCode = 0x00
    private let VK_T: CGKeyCode = 0x11
    private let VK_ESC: CGKeyCode = 0x35

    // MARK: Mouse button numbers
    private let MOUSE_BUTTON_5: Int64 = 4
    private let MOUSE_BUTTON_3: Int64 = 2

    // MARK: Wheel click tracking
    private var wheelPendingWork: DispatchWorkItem?
    private let wheelDoubleClickWindow: TimeInterval = 0.35
    private var wheelLongPressWork: DispatchWorkItem?
    private let wheelLongPressThreshold: TimeInterval = 0.6

    // MARK: Tap reference (kept alive for re-enable on timeout)
    private var tapPort: CFMachPort?
    var isActive: Bool { tapPort != nil }

    // MARK: - Start

    func start() {
        let eventsOfInterest: CGEventMask =
            CGEventMask(1 << CGEventType.keyDown.rawValue) |
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
            // DEBUG: log all extra mouse button events
            let logLine = "otherMouseDown button=\(button) (MOUSE_BUTTON_5=\(MOUSE_BUTTON_5) MOUSE_BUTTON_3=\(MOUSE_BUTTON_3))\n"
            if let data = logLine.data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: "/tmp/victor-mouse.log") {
                    fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                } else {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/victor-mouse.log"))
                }
            }
            if button == MOUSE_BUTTON_5 && event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
                onDictationMute?()
            } else if button == MOUSE_BUTTON_3 {
                handleWheelDown()
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

        // Option+Scroll → magnifier zoom (suppress native macOS zoom)
        if type == .scrollWheel {
            let flags = event.flags
            guard flags.contains(.maskAlternate) &&
                  !flags.contains(.maskCommand) &&
                  !flags.contains(.maskControl) else {
                return Unmanaged.passUnretained(event)
            }
            let delta = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            if delta != 0 {
                DispatchQueue.global().async { [weak self] in self?.onZoomScroll?(delta) }
            }
            return nil  // suppress — prevents native macOS zoom from activating
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

        // ESC → let Wispr handle it, but also resume media if we paused for dictation (pass through)
        if keyCode == VK_ESC {
            let logLine = "\(Date()) ESC detected\n"
            if let data = logLine.data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: "/tmp/victor-esc.log") {
                    fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                } else {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/victor-esc.log"))
                }
            }
            DispatchQueue.global().async { [weak self] in self?.onDictationEscape?() }
            return Unmanaged.passUnretained(event)
        }

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

    // MARK: - Wheel long-press and double-click

    private func handleWheelDown() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.wheelLongPressWork = nil
                DispatchQueue.global().async { self.onWheelLongPress?() }
            }
            self.wheelLongPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.wheelLongPressThreshold, execute: work)
        }
    }

    private func handleWheelUp() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let work = self.wheelLongPressWork else { return }  // long press already fired
            work.cancel()
            self.wheelLongPressWork = nil
            self.handleShortWheelClick()
        }
    }

    private func handleShortWheelClick() {
        if wheelPendingWork != nil {
            // Second short click within window = double click
            wheelPendingWork?.cancel()
            wheelPendingWork = nil
            DispatchQueue.global().async { [weak self] in self?.onRepaste?() }
        } else {
            // First short click — start window
            let work = DispatchWorkItem { [weak self] in
                self?.wheelPendingWork = nil
            }
            wheelPendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wheelDoubleClickWindow, execute: work)
        }
    }

    // MARK: - Clipboard helper

    private func getClipboardText() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}
