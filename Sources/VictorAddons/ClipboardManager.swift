import AppKit

enum ClipboardManager {
    static func read() -> String {
        return PasteboardGate.sync { $0.string(forType: .string) ?? "" }
    }

    static func write(_ text: String) {
        PasteboardGate.sync { pb in
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }
}
