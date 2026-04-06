import AppKit

enum ClipboardManager {
    static func read() -> String {
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
