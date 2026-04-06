import AppKit
import Foundation

class EmotionalPasteHandler {
    private let cleanup: ClaudeCleanup?
    private var lastPasteText: String = ""
    private var isRunning = false  // simple lock
    private let lock = NSLock()

    init(apiKey: String) {
        cleanup = ClaudeCleanup(apiKey: apiKey)
    }

    // Called on Cmd+V capture (from EventTapManager.onCaptureClipboard)
    func captureText(_ text: String) {
        lastPasteText = text
    }

    // Called on Cmd+Ctrl+V (from EventTapManager.onEmotionalPaste)
    func handleCleanHotkey() {
        // Run on background thread
        Task.detached { [weak self] in
            await self?.performClean()
        }
    }

    private func performClean() async {
        // Non-reentrant: skip if already running
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()
        defer {
            lock.lock()
            isRunning = false
            lock.unlock()
        }

        // Play sound
        playTinkSound()

        let text = lastPasteText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlayInfo("Skipped: no captured paste text")
            return
        }
        guard text.count <= 5000 else {
            overlayInfo("Skipped: text too long (\(text.count) chars > 5000)")
            return
        }
        guard let cleanup = cleanup else {
            overlayInfo("Skipped: no API key configured")
            return
        }

        overlayInfo("Cleaning \(text.count) chars...")
        let start = Date()

        do {
            let (cleaned, cost) = try await cleanup.clean(text)

            // Undo the original paste, then paste cleaned text
            await MainActor.run {
                KeySimulator.cmdZ()
            }
            try? await Task.sleep(nanoseconds: 150_000_000)  // 0.15s

            await MainActor.run {
                ClipboardManager.write(cleaned)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)   // 0.05s

            await MainActor.run {
                KeySimulator.cmdV()
            }

            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let preview = String(cleaned.prefix(200))
            overlayInfo("Done (\(text.count)→\(cleaned.count) chars, \(elapsed)ms, $\(String(format: "%.4f", cost))):\n  \(preview)")
        } catch {
            overlayInfo("Failed: \(error)")
        }
    }

    // Called on wheel double-click (from EventTapManager.onRepaste)
    func repasteLast() {
        let text = lastPasteText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlayInfo("Skipped: no captured paste text to repaste")
            return
        }
        let previous = ClipboardManager.read()
        ClipboardManager.write(text)
        Thread.sleep(forTimeInterval: 0.05)
        KeySimulator.cmdV()
        Thread.sleep(forTimeInterval: 0.05)
        ClipboardManager.write(previous)
        overlayInfo("Repasted last captured text (\(text.count) chars)")
    }

    private func playTinkSound() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["/System/Library/Sounds/Tink.aiff"]
        try? p.run()
    }
}
