import CoreGraphics
import Foundation

enum KeySimulator {
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

    static func cmdV() { simulateKeyPress(keyCode: 0x09, flags: .maskCommand) }
    static func cmdZ() { simulateKeyPress(keyCode: 0x06, flags: .maskCommand) }

    static func simulateDoubleOptionPress() {
        let src = CGEventSource(stateID: .hidSystemState)
        let optKey: CGKeyCode = 0x3A  // kVK_Option
        CGEvent(keyboardEventSource: src, virtualKey: optKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: optKey, keyDown: false)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        CGEvent(keyboardEventSource: src, virtualKey: optKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: optKey, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
