import AppKit
import Foundation

// MARK: - LogBuffer

class LogBuffer {
    static let shared = LogBuffer()
    private var entries: [String] = []
    private let maxEntries = 50
    private let lock = NSLock()

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst() }
        lock.unlock()
    }

    func allEntries() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

// MARK: - LogWindow

class LogWindow {
    private var panel: NSPanel?

    func show() {
        let logText = LogBuffer.shared.allEntries().joined(separator: "\n")

        guard let screen = NSScreen.main else { return }
        let w = screen.frame.width * 0.7
        let h = screen.frame.height * 0.7
        let x = (screen.frame.width - w) / 2
        let y = (screen.frame.height - h) / 2

        let newPanel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Log"
        newPanel.level = .floating

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let textView = ClickToCopyTextView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = false
        textView.string = logText.isEmpty ? "(no log entries yet)" : logText
        textView.autoresizingMask = [.width, .height]

        scrollView.documentView = textView
        newPanel.contentView?.addSubview(scrollView)

        panel = newPanel  // retain
        NSApplication.shared.activate(ignoringOtherApps: true)
        newPanel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - ClickToCopyTextView

private class ClickToCopyTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        // Copy all text to clipboard on click
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
