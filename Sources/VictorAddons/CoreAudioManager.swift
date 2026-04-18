import Foundation

class CoreAudioManager {
    private static let nowPlayingCLI = "/opt/homebrew/bin/nowplaying-cli"

    private var isDictationActive = false

    // Toggle media pause/resume: call from EventTapManager.onDictationMute callback
    func toggleDictationMute() {
        if isDictationActive {
            resumeMedia()
        } else {
            pauseMedia()
        }
    }

    private func pauseMedia() {
        runNowPlaying("pause")
        isDictationActive = true
        overlayInfo("🟢 Dictation: ⏸ media paused")
    }

    private func resumeMedia() {
        runNowPlaying("play")
        isDictationActive = false
        overlayInfo("🔴 Dictation: ▶ media resumed")
    }

    private func runNowPlaying(_ command: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.nowPlayingCLI)
        proc.arguments = [command]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            overlayInfo("WARNING: nowplaying-cli \(command) failed: \(error.localizedDescription)")
        }
    }
}
