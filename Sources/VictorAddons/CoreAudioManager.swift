import AppKit
import Foundation

class CoreAudioManager {
    private var isDictationActive = false

    // Toggle media pause/resume: call from EventTapManager.onDictationMute callback
    func toggleDictationMute() {
        if isDictationActive {
            resumeMedia()
        } else {
            pauseMedia()
        }
    }

    // Called on global ESC: if we paused media for dictation, Wispr was cancelled → resume.
    func resumeIfDictationActive() {
        guard isDictationActive else { return }
        resumeMedia()
    }

    private func pauseMedia() {
        guard isMediaPlaying() else {
            overlayInfo("🟡 Dictation: no media playing, skipping mute")
            return
        }
        postPlayPauseKey()
        isDictationActive = true
        overlayInfo("🟢 Dictation: ⏸ media paused")
    }

    private func isMediaPlaying() -> Bool {
        let candidates = ["/opt/homebrew/bin/nowplaying-cli", "/usr/local/bin/nowplaying-cli"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return true  // conservative: assume playing if tool not found
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["get", "playbackRate"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let rate = Double(output) else { return false }  // "null" or empty → nothing playing
        return rate > 0
    }

    private func resumeMedia() {
        postPlayPauseKey()
        isDictationActive = false
        overlayInfo("🔴 Dictation: ▶ media resumed")
    }

    // NX_KEYTYPE_PLAY=16 — same signal the hardware Play/Pause key sends.
    // Works for YouTube in browsers, Spotify, Music, etc. — anything that
    // listens for the system media key. Replaces nowplaying-cli which is
    // broken on macOS 15+ because Apple locked down MediaRemote.framework.
    private func postPlayPauseKey() {
        let NX_KEYTYPE_PLAY: Int32 = 16
        for flagsDown in [0xA00, 0xB00] {
            let data1 = (Int(NX_KEYTYPE_PLAY) << 16) | flagsDown
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flagsDown)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
